// Command psiphon-service runs psiphon-tunnel-core as a Windows service.
//
// The tunnel core is an ordinary console program and knows nothing about the
// service control manager, so this wrapper handles that side of things: start
// the tunnel, restart it if it exits, reload it when the config file changes,
// and stop it cleanly when Windows stops the service.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

const serviceName = "PsiphonTunnelCore"

var (
	kernel32         = windows.NewLazySystemDLL("kernel32.dll")
	procAllocConsole = kernel32.NewProc("AllocConsole")
	procFreeConsole  = kernel32.NewProc("FreeConsole")
)

type settings struct {
	App    string   `json:"app"`
	Args   []string `json:"args"`
	LogDir string   `json:"logDir"`
	Watch  []string `json:"watch"`
}

type logger struct {
	mu   sync.Mutex
	file *os.File
}

func newLogger(dir string) (*logger, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "service.log")
	if info, err := os.Stat(path); err == nil && info.Size() > 5*1024*1024 {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	return &logger{file: f}, nil
}

func (l *logger) printf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	fmt.Fprintf(l.file, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}

func (l *logger) close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	_ = l.file.Close()
}

type host struct {
	settings settings
	log      *logger
	mu       sync.Mutex
	watched  map[string]string
}

func main() {
	path := settingsPath()
	s, err := loadSettings(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot load settings %q: %v\n", path, err)
		os.Exit(1)
	}

	isService, err := svc.IsWindowsService()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot determine session type: %v\n", err)
		os.Exit(1)
	}

	if !isService {
		runConsole(s)
		return
	}

	h := &host{settings: s, watched: map[string]string{}}
	if err := svc.Run(serviceName, h); err != nil {
		fmt.Fprintf(os.Stderr, "service failed: %v\n", err)
		os.Exit(1)
	}
}

func settingsPath() string {
	for _, arg := range os.Args[1:] {
		if arg != "-console" {
			return arg
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return "service.json"
	}
	return filepath.Join(filepath.Dir(exe), "service.json")
}

func loadSettings(path string) (settings, error) {
	var s settings
	data, err := os.ReadFile(path)
	if err != nil {
		return s, err
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return s, err
	}
	if s.App == "" {
		return s, fmt.Errorf("missing \"app\" setting")
	}
	if s.LogDir == "" {
		s.LogDir = filepath.Dir(path)
	}
	return s, nil
}

func (h *host) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	log, err := newLogger(h.settings.LogDir)
	if err != nil {
		status <- svc.Status{State: svc.Stopped}
		return true, 1
	}
	h.log = log
	defer log.close()

	// A service starts without a console. Giving it one lets the child share
	// it, which is what makes CTRL_BREAK (graceful shutdown) possible.
	procAllocConsole.Call()
	defer procFreeConsole.Call()

	log.printf("service starting")
	h.recordWatched()
	status <- svc.Status{State: svc.StartPending}

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		cmd, wait, err := h.startChild()
		if err != nil {
			log.printf("cannot start tunnel core: %v", err)
			status <- svc.Status{State: svc.Stopped}
			return true, 1
		}
		status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

		reload := false

	watch:
		for {
			select {
			case req := <-requests:
				switch req.Cmd {
				case svc.Interrogate:
					status <- req.CurrentStatus
				case svc.Stop, svc.Shutdown:
					status <- svc.Status{State: svc.StopPending}
					h.stopChild(cmd, wait)
					status <- svc.Status{State: svc.Stopped}
					log.printf("service stopped")
					return false, 0
				}
			case <-wait:
				log.printf("tunnel core exited")
				break watch
			case <-ticker.C:
				if h.configChanged() {
					log.printf("config changed, restarting tunnel core")
					h.stopChild(cmd, wait)
					reload = true
					break watch
				}
			}
		}

		if reload {
			continue
		}

		// Give the tunnel a moment before a crash restart, but keep answering
		// stop requests while waiting.
		pause := time.NewTimer(5 * time.Second)
	waiting:
		for {
			select {
			case req := <-requests:
				switch req.Cmd {
				case svc.Interrogate:
					status <- req.CurrentStatus
				case svc.Stop, svc.Shutdown:
					pause.Stop()
					status <- svc.Status{State: svc.Stopped}
					log.printf("service stopped")
					return false, 0
				}
			case <-pause.C:
				break waiting
			}
		}
	}
}

func (h *host) startChild() (*exec.Cmd, <-chan error, error) {
	cmd := exec.Command(h.settings.App, h.settings.Args...)
	cmd.Dir = filepath.Dir(h.settings.App)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP}

	stdout, err := openRotating(filepath.Join(h.settings.LogDir, "psiphon.out.log"))
	if err != nil {
		return nil, nil, err
	}
	stderr, err := openRotating(filepath.Join(h.settings.LogDir, "psiphon.err.log"))
	if err != nil {
		stdout.Close()
		return nil, nil, err
	}
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		stdout.Close()
		stderr.Close()
		return nil, nil, err
	}
	h.log.printf("tunnel core started (pid %d)", cmd.Process.Pid)

	wait := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		stdout.Close()
		stderr.Close()
		wait <- err
	}()
	return cmd, wait, nil
}

func (h *host) stopChild(cmd *exec.Cmd, wait <-chan error) {
	h.log.printf("stopping tunnel core (pid %d)", cmd.Process.Pid)
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(cmd.Process.Pid))

	select {
	case <-wait:
		h.log.printf("tunnel core stopped")
		return
	case <-time.After(15 * time.Second):
	}

	h.log.printf("tunnel core did not stop in time, killing it")
	_ = cmd.Process.Kill()
	select {
	case <-wait:
	case <-time.After(5 * time.Second):
	}
}

func (h *host) recordWatched() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.watched = make(map[string]string, len(h.settings.Watch))
	for _, path := range h.settings.Watch {
		h.watched[path] = fileSignature(path)
	}
}

func (h *host) configChanged() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	changed := false
	for _, path := range h.settings.Watch {
		sig := fileSignature(path)
		if h.watched[path] != sig {
			h.watched[path] = sig
			changed = true
		}
	}
	return changed
}

func fileSignature(path string) string {
	info, err := os.Stat(path)
	if err != nil {
		return "missing"
	}
	return fmt.Sprintf("%d:%d", info.ModTime().UnixNano(), info.Size())
}

func openRotating(path string) (*os.File, error) {
	if info, err := os.Stat(path); err == nil && info.Size() > 10*1024*1024 {
		_ = os.Rename(path, path+".1")
	}
	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
}

// runConsole is used when the binary is started by hand, e.g. for a quick
// test without installing the service.
func runConsole(s settings) {
	log, err := newLogger(s.LogDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot open log: %v\n", err)
		os.Exit(1)
	}
	defer log.close()

	h := &host{settings: s, log: log, watched: map[string]string{}}
	cmd, wait, err := h.startChild()
	if err != nil {
		log.printf("cannot start tunnel core: %v", err)
		os.Exit(1)
	}
	log.printf("running in foreground, press Ctrl+C to stop")

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	<-signals

	h.stopChild(cmd, wait)
}
