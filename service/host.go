//go:build windows

package main

import (
	"fmt"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

var (
	kernel32         = windows.NewLazySystemDLL("kernel32.dll")
	procAllocConsole = kernel32.NewProc("AllocConsole")
	procFreeConsole  = kernel32.NewProc("FreeConsole")
)

// host implements svc.Handler. It keeps one tunnel alive and restarts it after
// a crash or a config change.
type host struct {
	cfg     config
	log     *logger
	mu      sync.Mutex
	watched map[string]string
}

func newHost(cfg config) *host {
	return &host{cfg: cfg, watched: make(map[string]string)}
}

// result explains why the watch loop returned.
type result int

const (
	crashed result = iota
	reloaded
	stopped
)

func (h *host) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	log, err := newLogger(h.cfg.LogDir)
	if err != nil {
		status <- svc.Status{State: svc.Stopped}
		return true, 1
	}

	h.log = log
	defer log.Close()

	// A service starts without a console. Allocating one so the child shares
	// it is what makes CTRL_BREAK, and therefore a clean shutdown, possible.
	giveConsole()
	defer freeConsole()

	log.Printf("service starting")
	h.rememberConfig()

	status <- svc.Status{State: svc.StartPending}

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		child, err := startChild(h.cfg, log)
		if err != nil {
			log.Printf("start: %v", err)
			status <- svc.Status{State: svc.Stopped}
			return true, 1
		}

		status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

		switch h.watch(child, requests, status, ticker) {
		case stopped:
			status <- svc.Status{State: svc.Stopped}
			log.Printf("service stopped")
			return false, 0

		case reloaded:
			continue
		}

		if h.waitBeforeRestart(requests, status) {
			return false, 0
		}
	}
}

func (h *host) watch(child *child, requests <-chan svc.ChangeRequest, status chan<- svc.Status, ticker *time.Ticker) result {
	for {
		select {
		case req := <-requests:
			switch req.Cmd {
			case svc.Interrogate:
				status <- req.CurrentStatus

			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				child.stop(h.log)
				return stopped
			}

		case <-child.wait:
			h.log.Printf("tunnel core exited")
			return crashed

		case <-ticker.C:
			if h.configChanged() {
				h.log.Printf("config changed, reloading tunnel core")
				child.stop(h.log)
				return reloaded
			}
		}
	}
}

// waitBeforeRestart gives a crashed tunnel a moment, while still answering
// stop requests. It reports whether the service was stopped.
func (h *host) waitBeforeRestart(requests <-chan svc.ChangeRequest, status chan<- svc.Status) bool {
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()

	for {
		select {
		case req := <-requests:
			switch req.Cmd {
			case svc.Interrogate:
				status <- req.CurrentStatus

			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.Stopped}
				h.log.Printf("service stopped")
				return true
			}

		case <-timer.C:
			return false
		}
	}
}

func giveConsole() {
	procAllocConsole.Call()
}

func freeConsole() {
	procFreeConsole.Call()
}

// rememberConfig records the current state of every watched file so the next
// poll can tell whether something changed.
func (h *host) rememberConfig() {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.watched = make(map[string]string, len(h.cfg.Watch))
	for _, path := range h.cfg.Watch {
		h.watched[path] = signature(path)
	}
}

func (h *host) configChanged() bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	changed := false

	for _, path := range h.cfg.Watch {
		sum := signature(path)
		if h.watched[path] != sum {
			h.watched[path] = sum
			changed = true
		}
	}

	return changed
}

func signature(path string) string {
	info, err := os.Stat(path)
	if err != nil {
		return "missing"
	}

	return fmt.Sprintf("%d:%d", info.ModTime().UnixNano(), info.Size())
}
