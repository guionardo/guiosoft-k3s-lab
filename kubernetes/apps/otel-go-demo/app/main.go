package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

var (
	serviceName   = envOrDefault("SERVICE_NAME", "otel-go-demo")
	downstreamURL = os.Getenv("DOWNSTREAM_URL")
	httpClient    = &http.Client{Timeout: 3 * time.Second}
)

func main() {
	ctx := context.Background()
	shutdownTracing, err := initTracing(ctx)
	if err != nil {
		log.Fatalf("initialize tracing: %v", err)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := shutdownTracing(shutdownCtx); err != nil {
			log.Printf("shutdown tracing: %v", err)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/work", workHandler)
	mux.HandleFunc("/process", processHandler)

	server := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("%s listening on %s", serviceName, server.Addr)
		if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("http server: %v", err)
		}
	}()

	sigCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-sigCtx.Done()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown http server: %v", err)
	}
}

func initTracing(ctx context.Context) (func(context.Context) error, error) {
	endpoint := envOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317")

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}

	res := resource.NewWithAttributes(
		"",
		attribute.String("service.name", serviceName),
		attribute.String("service.version", "0.2.0"),
		attribute.String("deployment.environment", "homelab"),
	)

	provider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
		sdktrace.WithResource(res),
	)

	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	return provider.Shutdown, nil
}

func workHandler(w http.ResponseWriter, r *http.Request) {
	ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
	tracer := otel.Tracer(serviceName)
	ctx, span := tracer.Start(ctx, "HTTP GET /work",
		trace.WithSpanKind(trace.SpanKindServer),
		trace.WithAttributes(
			attribute.String("http.request.method", r.Method),
			attribute.String("url.path", r.URL.Path),
		),
	)
	defer span.End()

	simulateStage(ctx, tracer, "validate.request", 8, 25)
	simulateStage(ctx, tracer, "database.lookup", 20, 60)
	simulateStage(ctx, tracer, "business.calculate", 15, 45)

	downstream := "disabled"
	if downstreamURL != "" {
		if err := callDownstream(ctx, tracer); err != nil {
			span.RecordError(err)
			http.Error(w, fmt.Sprintf("downstream call failed: %v", err), http.StatusBadGateway)
			return
		}
		downstream = "ok"
	} else {
		simulateStage(ctx, tracer, "external.call", 30, 90)
	}

	traceID := span.SpanContext().TraceID().String()
	log.Printf("request completed service=%s method=%s path=%s trace_id=%s downstream=%s", serviceName, r.Method, r.URL.Path, traceID, downstream)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Trace-ID", traceID)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"service":    serviceName,
		"trace_id":   traceID,
		"downstream": downstream,
		"message":    "trace emitted through OpenTelemetry Collector",
	})
}

func processHandler(w http.ResponseWriter, r *http.Request) {
	ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
	tracer := otel.Tracer(serviceName)
	ctx, span := tracer.Start(ctx, "HTTP GET /process",
		trace.WithSpanKind(trace.SpanKindServer),
		trace.WithAttributes(
			attribute.String("http.request.method", r.Method),
			attribute.String("url.path", r.URL.Path),
		),
	)
	defer span.End()

	simulateStage(ctx, tracer, "downstream.load", 15, 45)
	simulateStage(ctx, tracer, "downstream.calculate", 20, 70)

	traceID := span.SpanContext().TraceID().String()
	log.Printf("request completed service=%s method=%s path=%s trace_id=%s", serviceName, r.Method, r.URL.Path, traceID)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"service":  serviceName,
		"trace_id": traceID,
		"status":   "processed",
	})
}

func callDownstream(ctx context.Context, tracer trace.Tracer) error {
	ctx, span := tracer.Start(ctx, "HTTP GET downstream /process",
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(attribute.String("server.address", downstreamURL)),
	)
	defer span.End()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, downstreamURL, nil)
	if err != nil {
		return err
	}
	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("unexpected status %s", resp.Status)
	}
	return nil
}

func simulateStage(ctx context.Context, tracer trace.Tracer, name string, minMs, maxMs int) {
	ctx, span := tracer.Start(ctx, name, trace.WithSpanKind(trace.SpanKindInternal))
	defer span.End()

	delay := minMs + rand.IntN(maxMs-minMs+1)
	span.SetAttributes(
		attribute.String("demo.stage", name),
		attribute.Int("demo.delay_ms", delay),
	)

	select {
	case <-time.After(time.Duration(delay) * time.Millisecond):
	case <-ctx.Done():
		span.RecordError(ctx.Err())
	}
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
