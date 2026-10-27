//go:build windows

package main

import (
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

// child is the running tunnel process. wait delivers its exit status once.
type child struct {
	cmd  *exec.Cmd
	wait <-chan error
}

func startChild(cfg config, log *logger) (*child, error) {
	cmd := exec.Command(cfg.App, cfg.Args...)
	cmd.Dir = filepath.Dir(cfg.App)

	// Its own process group lets us send CTRL_BREAK to the tunnel without
	// touching the service process.
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP,
	}

	stdout, err := openLog(filepath.Join(cfg.LogDir, "psiphon.out.log"), 10<<20)
	if err != nil {
		return nil, err
	}

	stderr, err := openLog(filepath.Join(cfg.LogDir, "psiphon.err.log"), 10<<20)
	if err != nil {
		stdout.Close()
		return nil, err
	}

	cmd.Stdout = stdout
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		stdout.Close()
		stderr.Close()
		return nil, err
	}

	log.Printf("tunnel core started (pid %d)", cmd.Process.Pid)

	wait := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		stdout.Close()
		stderr.Close()
		wait <- err
	}()

	return &child{cmd: cmd, wait: wait}, nil
}

// stop asks the tunnel to exit and kills it if it takes too long.
func (c *child) stop(log *logger) {
	log.Printf("stopping tunnel core (pid %d)", c.cmd.Process.Pid)
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(c.cmd.Process.Pid))

	select {
	case <-c.wait:
		log.Printf("tunnel core stopped")
		return
	case <-time.After(15 * time.Second):
	}

	log.Printf("tunnel core did not stop, killing it")
	_ = c.cmd.Process.Kill()

	select {
	case <-c.wait:
	case <-time.After(5 * time.Second):
	}
}
