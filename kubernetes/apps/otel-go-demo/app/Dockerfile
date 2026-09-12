FROM golang:1.27.1-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o /out/otel-go-demo .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY --from=build /out/otel-go-demo /usr/local/bin/otel-go-demo
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/otel-go-demo"]
