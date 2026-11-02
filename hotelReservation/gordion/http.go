package gordion

// HTTP middleware for the frontend: each route is one endpoint of the
// "frontend" recorder. The load generator sends its send time in the
// "gordion-sent" header (unix ns); the middleware moves it into the incoming
// gRPC metadata so Begin computes the admission wait (x) exactly as for a
// gRPC request. Without a transport tap the timer starts here, after the
// HTTP server has read and parsed the request, so x = header -> here covers
// the socket queue and the parse.

import (
	"net/http"
	"os"
	"sort"

	"google.golang.org/grpc/metadata"
)

const sentHeader = "gordion-sent"

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// HTTPHandler wraps next so that requests to the listed routes are recorded
// under the given endpoint names (route path -> endpoint name). Pass-through
// when recording is disabled.
func HTTPHandler(service string, next http.Handler, routes map[string]string) http.Handler {
	if !Enabled() {
		return next
	}
	names := make([]string, 0, len(routes))
	for _, n := range routes {
		names = append(names, n)
	}
	sort.Strings(names)
	rec, err := GetRecorder(service, service, names)
	if err != nil {
		os.Stderr.WriteString("gordion: " + err.Error() + "\n")
		return next
	}
	idx := map[string]int{}
	for p, n := range routes {
		for i, m := range names {
			if m == n {
				idx[p] = i
			}
		}
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m, ok := idx[r.URL.Path]
		if !ok {
			next.ServeHTTP(w, r)
			return
		}
		ctx := r.Context()
		if v := r.Header.Get(sentHeader); v != "" {
			ctx = metadata.NewIncomingContext(ctx, metadata.Pairs(sentKey, v))
		}
		ctx, tok := rec.Begin(ctx, m)
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r.WithContext(ctx))
		rec.End(tok, sw.status >= 500)
	})
}
