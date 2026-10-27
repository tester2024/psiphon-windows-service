//go:build windows

// Command psiphon-service runs psiphon-tunnel-core as a Windows service.
//
// The tunnel core is a console program, so this wrapper takes care of the
// service control manager: start the tunnel, restart it when it exits, reload
// it when the config file changes, and stop it cleanly on shutdown.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/windows/svc"
)

const serviceName = "PsiphonTunnelCore"

func main() {
	cfg, err := loadConfig(configPath())
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	inService, err := svc.IsWindowsService()
	if err != nil {
		fmt.Fprintf(os.Stderr, "session check: %v\n", err)
		os.Exit(1)
	}

	if !inService {
		runForeground(cfg)
		return
	}

	if err := svc.Run(serviceName, newHost(cfg)); err != nil {
		fmt.Fprintf(os.Stderr, "service: %v\n", err)
		os.Exit(1)
	}
}

// configPath returns the settings file passed on the command line, or
// service.json next to the executable when started by Windows.
func configPath() string {
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

// runForeground is the path used when the binary is started by hand, e.g. for
// a quick test without installing the service.
func runForeground(cfg config) {
	log, err := newLogger(cfg.LogDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "log: %v\n", err)
		os.Exit(1)
	}

	defer log.Close()

	child, err := startChild(cfg, log)
	if err != nil {
		log.Printf("start: %v", err)
		os.Exit(1)
	}

	log.Printf("running in foreground, press Ctrl+C to stop")

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	<-signals

	child.stop(log)
}
