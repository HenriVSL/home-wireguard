package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"
)

const (
	stateDir      = "/state"
	versionFile   = "/etc/home-wireguard/version.json"
	staleAfter    = 8 * 24 * time.Hour // weekly cron + a day of slack
	ciCacheTTL    = 15 * time.Minute
	ciFailBackoff = 2 * time.Minute
)

// Written by the Dockerfile from CI build args.
type buildInfo struct {
	Version string `json:"version"`
	Commit  string `json:"commit"`
	Built   string `json:"built"`
	Repo    string `json:"repo"`
}

// Written by update.sh on the host.
type updateState struct {
	Time    string `json:"time"`
	Result  string `json:"result"`
	Message string `json:"message"`
}

type ciRun struct {
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	HTMLURL    string `json:"html_url"`
	CreatedAt  string `json:"created_at"`
	Event      string `json:"event"`
}

type notice struct {
	Level string // "error", "warn", "info"
	Text  string
	Link  string
}

type statusView struct {
	Build        buildInfo
	CommitURL    string
	Components   []string
	Started      string
	LastUpdate   string
	LastCheck    string
	CheckResult  string
	CIText       string
	CIURL        string
	ActionsURL   string
	Notices      []notice
	ClientsTotal int
	ClientsLive  int
}

var (
	componentsOnce sync.Once
	components     []string
	startedAt      = time.Now()

	ciMu      sync.Mutex
	ciCache   []ciRun
	ciErr     error
	ciFetched time.Time
)

func readBuildInfo() buildInfo {
	b := buildInfo{Version: "dev"}
	if data, err := os.ReadFile(versionFile); err == nil {
		_ = json.Unmarshal(data, &b)
	}
	return b
}

func readState(name string) (updateState, time.Time, bool) {
	var s updateState
	data, err := os.ReadFile(stateDir + "/" + name)
	if err != nil || json.Unmarshal(data, &s) != nil {
		return s, time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s.Time)
	if err != nil {
		return s, time.Time{}, false
	}
	return s, t, true
}

func componentVersions() []string {
	componentsOnce.Do(func() {
		if v, err := os.ReadFile("/etc/alpine-release"); err == nil {
			components = append(components, "Alpine "+strings.TrimSpace(string(v)))
		}
		if out, err := exec.Command("wg", "--version").Output(); err == nil {
			if f := strings.Fields(string(out)); len(f) >= 2 {
				components = append(components, "wireguard-tools "+f[1])
			}
		}
		components = append(components, strings.Replace(runtime.Version(), "go", "Go ", 1))
		if out, err := exec.Command("uname", "-r").Output(); err == nil {
			components = append(components, "host kernel "+strings.TrimSpace(string(out)))
		}
	})
	return components
}

// Latest runs of the CI workflow on main, cached. Public repo: no token needed.
func ciRuns(repo string) ([]ciRun, error) {
	ciMu.Lock()
	defer ciMu.Unlock()
	ttl := ciCacheTTL
	if ciErr != nil {
		ttl = ciFailBackoff
	}
	if !ciFetched.IsZero() && time.Since(ciFetched) < ttl {
		return ciCache, ciErr
	}
	ciFetched = time.Now()
	ciCache, ciErr = fetchCIRuns(repo)
	return ciCache, ciErr
}

func fetchCIRuns(repo string) ([]ciRun, error) {
	if repo == "" {
		return nil, fmt.Errorf("repository unknown (local build)")
	}
	url := "https://api.github.com/repos/" + repo + "/actions/workflows/ci.yml/runs?branch=main&per_page=10"
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub answered %s", resp.Status)
	}
	var body struct {
		Runs []ciRun `json:"workflow_runs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	return body.Runs, nil
}

func buildStatus(devs []device) statusView {
	now := time.Now()
	b := readBuildInfo()
	v := statusView{Build: b, Components: componentVersions(), Started: when(startedAt)}
	if b.Repo != "" {
		v.ActionsURL = "https://github.com/" + b.Repo + "/actions/workflows/ci.yml"
		if b.Commit != "" {
			v.CommitURL = "https://github.com/" + b.Repo + "/commit/" + b.Commit
		}
	}

	v.ClientsTotal = len(devs)
	for _, d := range devs {
		if d.Handshake == "connected now" {
			v.ClientsLive++
		}
	}

	if _, t, ok := readState("last-update.json"); ok {
		v.LastUpdate = when(t)
	} else {
		v.LastUpdate = "not yet (installed by hand)"
	}

	if s, t, ok := readState("last-check.json"); ok {
		v.LastCheck = when(t)
		v.CheckResult = s.Message
		switch s.Result {
		case "rolled-back":
			v.Notices = append(v.Notices, notice{"error", "Automatic update on " + t.Local().Format("Mon 2 Jan") + " failed: " + s.Message + ". The VPN keeps working on the previous version. Run 'vpn logs' on the server for details.", ""})
		case "failed":
			v.Notices = append(v.Notices, notice{"error", "Automatic update on " + t.Local().Format("Mon 2 Jan") + " failed: " + s.Message + ". Run 'vpn logs' on the server for details.", ""})
		}
		if now.Sub(t) > staleAfter {
			v.Notices = append(v.Notices, notice{"warn", "Automatic updates haven't run since " + t.Local().Format("Mon 2 Jan") + ". Check the cron job on the server ('crontab -l').", ""})
		}
	} else {
		v.LastCheck = "never"
		v.Notices = append(v.Notices, notice{"info", "No automatic update has run yet. The first one runs on Tuesday night.", ""})
	}

	runs, err := ciRuns(b.Repo)
	switch {
	case err != nil:
		v.CIText = "unavailable (" + err.Error() + ")"
	case len(runs) == 0:
		v.CIText = "no runs yet"
	default:
		latest := runs[0]
		v.CIURL = latest.HTMLURL
		switch {
		case latest.Status != "completed":
			v.CIText = "running now"
		case latest.Conclusion == "success":
			v.CIText = "passing"
		default:
			v.CIText = latest.Conclusion
			v.Notices = append(v.Notices, notice{"error", "The latest GitHub test run " + latest.Conclusion + ". New versions are held back until it passes; the VPN keeps running the current version.", latest.HTMLURL})
		}
		if t, err := time.Parse(time.RFC3339, latest.CreatedAt); err == nil {
			v.CIText += ", " + when(t)
		}
		// Newer tested version published but not installed yet? A run that
		// started after this image was built produced a newer image (weekly
		// rebuilds keep the same commit, so compare times, not commits).
		built, berr := time.Parse(time.RFC3339, b.Built)
		for _, r := range runs {
			if r.Status == "completed" && r.Conclusion == "success" && r.Event != "pull_request" {
				if t, err := time.Parse(time.RFC3339, r.CreatedAt); berr == nil && err == nil && t.After(built) {
					v.Notices = append(v.Notices, notice{"info", "A newer tested version is available. It installs automatically on Tuesday night, or run 'vpn update' on the server.", ""})
				}
				break
			}
		}
	}
	return v
}

func when(t time.Time) string {
	d := time.Since(t)
	var rel string
	switch {
	case d < time.Minute:
		rel = "just now"
	case d < time.Hour:
		rel = fmt.Sprintf("%d min ago", int(d.Minutes()))
	case d < 48*time.Hour:
		rel = fmt.Sprintf("%d h ago", int(d.Hours()))
	default:
		rel = fmt.Sprintf("%d days ago", int(d.Hours()/24))
	}
	return t.Local().Format("Mon 2 Jan 15:04") + " (" + rel + ")"
}
