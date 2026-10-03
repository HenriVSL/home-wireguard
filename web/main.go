// wg-web: small LAN-only management page for the WireGuard container.
//
// Standard library only. All changes go through the wgctl script, so the web
// page and the command line always behave the same way.
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	dataDir    = "/data/clients"
	cookieName = "wgweb"
	sessionTTL = 12 * time.Hour
)

var (
	//go:embed templates/*.html
	templateFS embed.FS
	tmpl       = template.Must(template.ParseFS(templateFS, "templates/*.html"))

	validName = regexp.MustCompile(`^[A-Za-z0-9_-]{1,32}$`)
	password  []byte

	sessionsMu sync.Mutex
	sessions   = map[string]time.Time{}

	// Serializes failed logins so guessing is limited to about one try per second.
	loginFailMu sync.Mutex
)

type device struct {
	Name      string
	IP        string
	Handshake string
}

func main() {
	password = []byte(os.Getenv("WEB_PASSWORD"))
	if len(password) == 0 {
		log.Fatal("WEB_PASSWORD not set")
	}
	addr := ":" + envOr("WEB_PORT_INTERNAL", "8080")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /login", loginPage)
	mux.HandleFunc("POST /login", loginSubmit)
	mux.HandleFunc("POST /logout", auth(logout))
	mux.HandleFunc("GET /{$}", auth(index))
	mux.HandleFunc("POST /add", auth(addDevice))
	mux.HandleFunc("GET /d/{name}", auth(devicePage))
	mux.HandleFunc("GET /d/{name}/remove", auth(removeConfirm))
	mux.HandleFunc("POST /d/{name}/remove", auth(removeDevice))
	mux.HandleFunc("GET /d/{name}/{file}", auth(deviceFile))

	srv := &http.Server{
		Addr:              addr,
		Handler:           securityHeaders(sameOrigin(mux)),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("wg-web listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ---------------------------------------------------------------- middleware

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

// Reject cross-site form posts (in addition to the SameSite=Strict cookie).
func sameOrigin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			if o := r.Header.Get("Origin"); o != "" && o != "http://"+r.Host && o != "https://"+r.Host {
				http.Error(w, "cross-origin request refused", http.StatusForbidden)
				return
			}
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
				http.Error(w, "cross-origin request refused", http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie(cookieName)
		if err == nil && validSession(c.Value) {
			next(w, r)
			return
		}
		if r.Method == http.MethodGet {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		http.Error(w, "not logged in", http.StatusUnauthorized)
	}
}

func validSession(tok string) bool {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	exp, ok := sessions[tok]
	if !ok || time.Now().After(exp) {
		delete(sessions, tok)
		return false
	}
	return true
}

// ---------------------------------------------------------------- login

func loginPage(w http.ResponseWriter, r *http.Request) {
	render(w, http.StatusOK, "login.html", map[string]any{"Error": ""})
}

func loginSubmit(w http.ResponseWriter, r *http.Request) {
	if subtle.ConstantTimeCompare([]byte(r.FormValue("password")), password) != 1 {
		loginFailMu.Lock()
		time.Sleep(time.Second)
		loginFailMu.Unlock()
		log.Printf("failed login from %s", r.RemoteAddr)
		render(w, http.StatusUnauthorized, "login.html", map[string]any{"Error": "Wrong password"})
		return
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		http.Error(w, "rng failure", http.StatusInternalServerError)
		return
	}
	tok := hex.EncodeToString(b)
	sessionsMu.Lock()
	for t, exp := range sessions {
		if time.Now().After(exp) {
			delete(sessions, t)
		}
	}
	sessions[tok] = time.Now().Add(sessionTTL)
	sessionsMu.Unlock()
	http.SetCookie(w, &http.Cookie{
		Name: cookieName, Value: tok, Path: "/", MaxAge: int(sessionTTL.Seconds()),
		HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func logout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(cookieName); err == nil {
		sessionsMu.Lock()
		delete(sessions, c.Value)
		sessionsMu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// ---------------------------------------------------------------- pages

func index(w http.ResponseWriter, r *http.Request) {
	devs, err := listDevices()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	render(w, http.StatusOK, "index.html", map[string]any{"Devices": devs, "Error": r.URL.Query().Get("error")})
}

func addDevice(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(r.FormValue("name"))
	if !validName.MatchString(name) {
		redirectErr(w, r, "Name must be 1-32 characters: letters, numbers, - or _")
		return
	}
	if out, err := exec.Command("wgctl", "add", name).CombinedOutput(); err != nil {
		redirectErr(w, r, strings.TrimSpace(strings.TrimPrefix(string(out), "error: ")))
		return
	}
	log.Printf("added device %s from %s", name, r.RemoteAddr)
	http.Redirect(w, r, "/d/"+name, http.StatusSeeOther)
}

func devicePage(w http.ResponseWriter, r *http.Request) {
	name, ok := deviceName(w, r)
	if !ok {
		return
	}
	ip, _ := os.ReadFile(filepath.Join(dataDir, name, "ip"))
	render(w, http.StatusOK, "device.html", map[string]any{"Name": name, "IP": strings.TrimSpace(string(ip)), "LAN": os.Getenv("WG_LAN_ROUTES")})
}

func removeConfirm(w http.ResponseWriter, r *http.Request) {
	name, ok := deviceName(w, r)
	if !ok {
		return
	}
	render(w, http.StatusOK, "remove.html", map[string]any{"Name": name})
}

func removeDevice(w http.ResponseWriter, r *http.Request) {
	name, ok := deviceName(w, r)
	if !ok {
		return
	}
	if out, err := exec.Command("wgctl", "remove", name).CombinedOutput(); err != nil {
		redirectErr(w, r, strings.TrimSpace(string(out)))
		return
	}
	log.Printf("removed device %s from %s", name, r.RemoteAddr)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// Serves <name>-full.conf, <name>-lan.png, etc.
func deviceFile(w http.ResponseWriter, r *http.Request) {
	name, ok := deviceName(w, r)
	if !ok {
		return
	}
	file := r.PathValue("file")
	var kind, ext string
	for _, k := range []string{"full", "lan"} {
		for _, e := range []string{"conf", "png"} {
			if file == k+"."+e {
				kind, ext = k, e
			}
		}
	}
	if kind == "" {
		http.NotFound(w, r)
		return
	}
	base := name + "-" + kind
	path := filepath.Join(dataDir, name, base+"."+ext)
	if ext == "conf" {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", `attachment; filename="`+base+`.conf"`)
	} else {
		w.Header().Set("Content-Type", "image/png")
	}
	http.ServeFile(w, r, path)
}

// ---------------------------------------------------------------- helpers

func deviceName(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.PathValue("name")
	if !validName.MatchString(name) {
		http.NotFound(w, r)
		return "", false
	}
	if _, err := os.Stat(filepath.Join(dataDir, name, "public.key")); err != nil {
		http.NotFound(w, r)
		return "", false
	}
	return name, true
}

func redirectErr(w http.ResponseWriter, r *http.Request, msg string) {
	http.Redirect(w, r, "/?error="+template.URLQueryEscaper(msg), http.StatusSeeOther)
}

func listDevices() ([]device, error) {
	entries, err := os.ReadDir(dataDir)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	handshakes := map[string]int64{}
	if out, err := exec.Command("wg", "show", "wg0", "latest-handshakes").Output(); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			if f := strings.Fields(line); len(f) == 2 {
				handshakes[f[0]], _ = strconv.ParseInt(f[1], 10, 64)
			}
		}
	}
	var devs []device
	for _, e := range entries {
		dir := filepath.Join(dataDir, e.Name())
		pub, err := os.ReadFile(filepath.Join(dir, "public.key"))
		if err != nil {
			continue
		}
		ip, _ := os.ReadFile(filepath.Join(dir, "ip"))
		devs = append(devs, device{
			Name:      e.Name(),
			IP:        strings.TrimSpace(string(ip)),
			Handshake: ago(handshakes[strings.TrimSpace(string(pub))]),
		})
	}
	sort.Slice(devs, func(i, j int) bool { return strings.ToLower(devs[i].Name) < strings.ToLower(devs[j].Name) })
	return devs, nil
}

func ago(ts int64) string {
	if ts == 0 {
		return "never"
	}
	d := time.Since(time.Unix(ts, 0))
	switch {
	case d < 3*time.Minute:
		return "connected now"
	case d < time.Hour:
		return strconv.Itoa(int(d.Minutes())) + " min ago"
	case d < 48*time.Hour:
		return strconv.Itoa(int(d.Hours())) + " h ago"
	default:
		return strconv.Itoa(int(d.Hours()/24)) + " days ago"
	}
}

func render(w http.ResponseWriter, status int, name string, data map[string]any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := tmpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("template %s: %v", name, err)
	}
}
