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
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
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

	httpRequests = prometheus.NewCounterVec(
		prometheus.CounterOpts{Name: "otel_demo_http_requests_total", Help: "Total HTTP requests handled by the demo services."},
		[]string{"service", "method", "path", "status"},
	)
	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{Name: "otel_demo_http_request_duration_seconds", Help: "HTTP request latency for the demo services.", Buckets: prometheus.DefBuckets},
		[]string{"service", "method", "path"},
	)
	requestsInFlight = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{Name: "otel_demo_requests_in_flight", Help: "Current in-flight HTTP requests for instrumented demo endpoints."},
		[]string{"service", "path"},
	)
	downstreamRequests = prometheus.NewCounterVec(
		prometheus.CounterOpts{Name: "otel_demo_downstream_requests_total", Help: "Total downstream HTTP calls issued by the frontend demo service."},
		[]string{"service", "status"},
	)
	downstreamRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{Name: "otel_demo_downstream_request_duration_seconds", Help: "Latency of downstream HTTP calls issued by the frontend demo service.", Buckets: prometheus.DefBuckets},
		[]string{"service"},
	)
	downstreamErrors = prometheus.NewCounterVec(
		prometheus.CounterOpts{Name: "otel_demo_downstream_errors_total", Help: "Total failed downstream HTTP calls issued by the frontend demo service."},
		[]string{"service"},
	)
)

func init() {
	prometheus.MustRegister(httpRequests, httpRequestDuration, requestsInFlight, downstreamRequests, downstreamRequestDuration, downstreamErrors)
}

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
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/work", instrumentHTTP("/work", workHandler))
	mux.HandleFunc("/process", instrumentHTTP("/process", processHandler))

	server := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
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
	exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint(endpoint), otlptracegrpc.WithInsecure())
	if err != nil {
		return nil, err
	}
	res := resource.NewWithAttributes("", attribute.String("service.name", serviceName), attribute.String("service.version", "0.4.0"), attribute.String("deployment.environment", "homelab"))
	provider := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exporter), sdktrace.WithSampler(sdktrace.AlwaysSample()), sdktrace.WithResource(res))
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	return provider.Shutdown, nil
}

func workHandler(w http.ResponseWriter, r *http.Request) {
	ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
	tracer := otel.Tracer(serviceName)
	ctx, span := tracer.Start(ctx, "HTTP GET /work", trace.WithSpanKind(trace.SpanKindServer), trace.WithAttributes(attribute.String("http.request.method", r.Method), attribute.String("url.path", r.URL.Path)))
	defer span.End()

	traceID := span.SpanContext().TraceID().String()
	w.Header().Set("X-Trace-ID", traceID)

	simulateStage(ctx, tracer, "validate.request", 8, 25)
	simulateStage(ctx, tracer, "database.lookup", 20, 60)
	simulateStage(ctx, tracer, "business.calculate", 15, 45)

	downstream := "disabled"
	if downstreamURL != "" {
		if err := callDownstream(ctx, tracer); err != nil {
			span.RecordError(err)
			span.SetStatus(codes.Error, err.Error())
			span.SetAttributes(attribute.String("demo.downstream.status", "error"))
			log.Printf("request failed service=%s method=%s path=%s trace_id=%s downstream=error error=%q", serviceName, r.Method, r.URL.Path, traceID, err.Error())
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"service":    serviceName,
				"trace_id":   traceID,
				"downstream": "error",
				"error":      err.Error(),
			})
			return
		}
		downstream = "ok"
	} else {
		simulateStage(ctx, tracer, "external.call", 30, 90)
	}

	span.SetAttributes(attribute.String("demo.downstream.status", downstream))
	log.Printf("request completed service=%s method=%s path=%s trace_id=%s downstream=%s", serviceName, r.Method, r.URL.Path, traceID, downstream)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"service": serviceName, "trace_id": traceID, "downstream": downstream, "message": "trace emitted through OpenTelemetry Collector"})
}

func processHandler(w http.ResponseWriter, r *http.Request) {
	ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
	tracer := otel.Tracer(serviceName)
	ctx, span := tracer.Start(ctx, "HTTP GET /process", trace.WithSpanKind(trace.SpanKindServer), trace.WithAttributes(attribute.String("http.request.method", r.Method), attribute.String("url.path", r.URL.Path)))
	defer span.End()

	simulateStage(ctx, tracer, "downstream.load", 15, 45)
	simulateStage(ctx, tracer, "downstream.calculate", 20, 70)

	traceID := span.SpanContext().TraceID().String()
	log.Printf("request completed service=%s method=%s path=%s trace_id=%s", serviceName, r.Method, r.URL.Path, traceID)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Trace-ID", traceID)
	_ = json.NewEncoder(w).Encode(map[string]any{"service": serviceName, "trace_id": traceID, "status": "processed"})
}

func callDownstream(ctx context.Context, tracer trace.Tracer) (err error) {
	started := time.Now()
	status := "error"
	defer func() {
		downstreamRequestDuration.WithLabelValues(serviceName).Observe(time.Since(started).Seconds())
		downstreamRequests.WithLabelValues(serviceName, status).Inc()
		if err != nil {
			downstreamErrors.WithLabelValues(serviceName).Inc()
		}
	}()

	ctx, span := tracer.Start(ctx, "HTTP GET downstream /process", trace.WithSpanKind(trace.SpanKindClient), trace.WithAttributes(attribute.String("server.address", downstreamURL)))
	defer span.End()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, downstreamURL, nil)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return err
	}
	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	resp, err := httpClient.Do(req)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		status = "http_error"
		err = fmt.Errorf("unexpected status %s", resp.Status)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return err
	}
	status = "ok"
	return nil
}

func instrumentHTTP(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		requestsInFlight.WithLabelValues(serviceName, path).Inc()
		defer requestsInFlight.WithLabelValues(serviceName, path).Dec()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next(recorder, r)
		httpRequests.WithLabelValues(serviceName, r.Method, path, strconv.Itoa(recorder.status)).Inc()
		httpRequestDuration.WithLabelValues(serviceName, r.Method, path).Observe(time.Since(started).Seconds())
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func simulateStage(ctx context.Context, tracer trace.Tracer, name string, minMs, maxMs int) {
	ctx, span := tracer.Start(ctx, name, trace.WithSpanKind(trace.SpanKindInternal))
	defer span.End()
	delay := minMs + rand.IntN(maxMs-minMs+1)
	span.SetAttributes(attribute.String("demo.stage", name), attribute.Int("demo.delay_ms", delay))
	select {
	case <-time.After(time.Duration(delay) * time.Millisecond):
	case <-ctx.Done():
		span.RecordError(ctx.Err())
		span.SetStatus(codes.Error, ctx.Err().Error())
	}
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
