package main

import (
    "bytes"
    "context"
    "crypto/tls"
    "encoding/json"
    "fmt"
    "io"
    "log/slog"
    "net/http"
    "os"
    "os/signal"
    "strings"
    "sync"
    "syscall"
    "time"
)

// --- Configuration ---

type Config struct {
    ListenAddr     string
    TLSCertFile    string
    TLSKeyFile     string
    BotToken       string
    DefaultChatID  string
    AuthToken      string // Bearer token for incoming requests
    APIPath        string // customizable API endpoint path
    MaxRetries     int
    RequestTimeout time.Duration
}

func loadConfig() Config {
    return Config{
        ListenAddr:     envOrDefault("LISTEN_ADDR", ":10086"),
        TLSCertFile:    envOrDefault("TLS_CERT_FILE", "cert.pem"),
        TLSKeyFile:     envOrDefault("TLS_KEY_FILE", "key.pem"),
        BotToken:       requireEnv("TELEGRAM_BOT_TOKEN"),
        DefaultChatID:  requireEnv("TELEGRAM_CHAT_ID"),
        AuthToken:      envOrDefault("AUTH_TOKEN", ""),
        APIPath:        envOrDefault("API_PATH", "/forward"),
        MaxRetries:     3,
        RequestTimeout: 30 * time.Second,
    }
}

func envOrDefault(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}

func requireEnv(key string) string {
    v := os.Getenv(key)
    if v == "" {
        slog.Error("required environment variable not set", "key", key)
        os.Exit(1)
    }
    return v
}

// --- Models ---

// IncomingMessage is the JSON payload from clients.
type IncomingMessage struct {
    From    string `json:"from,omitempty"`    // sender identifier
    Subject string `json:"subject,omitempty"` // optional subject/title
    Body    string `json:"body"`              // message body (required)
}

// TelegramSendMessage is the Telegram Bot API sendMessage payload.
type TelegramSendMessage struct {
    ChatID    string `json:"chat_id"`
    Text      string `json:"text"`
    ParseMode string `json:"parse_mode,omitempty"`
}

// TelegramResponse is a simplified Telegram API response.
type TelegramResponse struct {
    OK          bool   `json:"ok"`
    Description string `json:"description,omitempty"`
    ErrorCode   int    `json:"error_code,omitempty"`
}

// --- Telegram Forwarder ---

type TelegramForwarder struct {
    botToken   string
    httpClient *http.Client
    maxRetries int
    mu         sync.Mutex // serialize sends to avoid Telegram rate limits
}

func NewTelegramForwarder(botToken string, maxRetries int, timeout time.Duration) *TelegramForwarder {
    return &TelegramForwarder{
        botToken:   botToken,
        maxRetries: maxRetries,
        httpClient: &http.Client{
            Timeout: timeout,
            Transport: &http.Transport{
                MaxIdleConns:        10,
                IdleConnTimeout:     90 * time.Second,
                TLSHandshakeTimeout: 10 * time.Second,
                TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
            },
        },
    }
}

func (tf *TelegramForwarder) Send(ctx context.Context, msg TelegramSendMessage) error {
    tf.mu.Lock()
    defer tf.mu.Unlock()

    url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", tf.botToken)

    payload, err := json.Marshal(msg)
    if err != nil {
        return fmt.Errorf("marshal telegram message: %w", err)
    }

    var lastErr error
    for attempt := 0; attempt <= tf.maxRetries; attempt++ {
        if attempt > 0 {
            backoff := time.Duration(attempt*attempt) * time.Second // quadratic backoff
            slog.Warn("retrying telegram send", "attempt", attempt, "backoff", backoff)
            select {
            case <-time.After(backoff):
            case <-ctx.Done():
                return fmt.Errorf("context cancelled during retry: %w", ctx.Err())
            }
        }

        req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
        if err != nil {
            return fmt.Errorf("create request: %w", err)
        }
        req.Header.Set("Content-Type", "application/json")

        resp, err := tf.httpClient.Do(req)
        if err != nil {
            lastErr = fmt.Errorf("http request failed: %w", err)
            continue
        }

        body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
        resp.Body.Close()

        if resp.StatusCode == http.StatusOK {
            var tgResp TelegramResponse
            if err := json.Unmarshal(body, &tgResp); err == nil && tgResp.OK {
                return nil
            }
        }

        // Rate limited by Telegram — respect Retry-After if present
        if resp.StatusCode == http.StatusTooManyRequests {
            lastErr = fmt.Errorf("telegram rate limited (429): %s", string(body))
            continue
        }

        // Non-retryable client errors (except 429)
        if resp.StatusCode >= 400 && resp.StatusCode < 500 {
            return fmt.Errorf("telegram API client error %d: %s", resp.StatusCode, string(body))
        }

        // Server errors — retryable
        lastErr = fmt.Errorf("telegram API error %d: %s", resp.StatusCode, string(body))
    }

    return fmt.Errorf("all %d retries exhausted: %w", tf.maxRetries, lastErr)
}

// --- HTTP Handler ---

type ForwardHandler struct {
    config    Config
    forwarder *TelegramForwarder
    logger    *slog.Logger
}

func NewForwardHandler(cfg Config, fwd *TelegramForwarder, logger *slog.Logger) *ForwardHandler {
    return &ForwardHandler{config: cfg, forwarder: fwd, logger: logger}
}

func (h *ForwardHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    // Only accept POST
    if r.Method != http.MethodPost {
        w.WriteHeader(http.StatusMethodNotAllowed)
        return
    }

    // Auth check
    if h.config.AuthToken != "" {
        auth := r.Header.Get("Authorization")
        expected := "Bearer " + h.config.AuthToken
        if auth != expected {
            w.WriteHeader(http.StatusUnauthorized)
            return
        }
    }

    // Read body with size limit (64KB)
    body, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
    if err != nil {
        w.WriteHeader(http.StatusBadRequest)
        return
    }
    defer r.Body.Close()

    // Parse incoming message
    var incoming IncomingMessage
    if err := json.Unmarshal(body, &incoming); err != nil {
        w.WriteHeader(http.StatusBadRequest)
        return
    }

    // Validate
    if strings.TrimSpace(incoming.Body) == "" {
        w.WriteHeader(http.StatusBadRequest)
        return
    }

    // Format the message text
    text := formatMessage(incoming)

    // Always send to the configured chat ID
    tgMsg := TelegramSendMessage{
        ChatID: h.config.DefaultChatID,
        Text:   text,
    }

    h.logger.Info("forwarding message",
        "from", incoming.From,
        "to", h.config.DefaultChatID,
        "body_len", len(incoming.Body),
    )

    if err := h.forwarder.Send(r.Context(), tgMsg); err != nil {
        h.logger.Error("failed to forward to telegram", "error", err)
        w.WriteHeader(http.StatusBadGateway)
        return
    }

    w.WriteHeader(http.StatusOK)
}

func formatMessage(msg IncomingMessage) string {
    var b strings.Builder

    if msg.From != "" {
        b.WriteString("📱 From: ")
        b.WriteString(msg.From)
        b.WriteString("\n")
    }
    if msg.Subject != "" {
        b.WriteString("📌 ")
        b.WriteString(msg.Subject)
        b.WriteString("\n")
    }
    if msg.From != "" || msg.Subject != "" {
        b.WriteString("─────────────\n")
    }
    b.WriteString(msg.Body)

    return b.String()
}

// --- Main ---

func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level: slog.LevelInfo,
    }))
    slog.SetDefault(logger)

    cfg := loadConfig()

    // Ensure API path starts with /
    if !strings.HasPrefix(cfg.APIPath, "/") {
        cfg.APIPath = "/" + cfg.APIPath
    }

    forwarder := NewTelegramForwarder(cfg.BotToken, cfg.MaxRetries, cfg.RequestTimeout)
    handler := NewForwardHandler(cfg, forwarder, logger)

    mux := http.NewServeMux()
    mux.Handle(cfg.APIPath, handler)

    server := &http.Server{
        Addr:         cfg.ListenAddr,
        Handler:      mux,
        ReadTimeout:  10 * time.Second,
        WriteTimeout: 30 * time.Second,
        IdleTimeout:  60 * time.Second,
        TLSConfig: &tls.Config{
            MinVersion:               tls.VersionTLS12,
            PreferServerCipherSuites: true,
        },
    }

    // Graceful shutdown
    go func() {
        sigCh := make(chan os.Signal, 1)
        signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
        sig := <-sigCh
        logger.Info("shutdown signal received", "signal", sig)

        ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
        defer cancel()

        if err := server.Shutdown(ctx); err != nil {
            logger.Error("forced shutdown", "error", err)
        }
    }()

    // Start server
    logger.Info("starting SMS forward proxy",
        "addr", cfg.ListenAddr,
        "api_path", cfg.APIPath,
        "tls_cert", cfg.TLSCertFile,
    )

    var err error
    if fileExists(cfg.TLSCertFile) && fileExists(cfg.TLSKeyFile) {
        logger.Info("TLS enabled")
        err = server.ListenAndServeTLS(cfg.TLSCertFile, cfg.TLSKeyFile)
    } else {
        logger.Warn("TLS cert/key not found, starting in plain HTTP mode (not recommended for production)")
        err = server.ListenAndServe()
    }

    if err != nil && err != http.ErrServerClosed {
        logger.Error("server error", "error", err)
        os.Exit(1)
    }

    logger.Info("server stopped gracefully")
}

func fileExists(path string) bool {
    _, err := os.Stat(path)
    return err == nil
}