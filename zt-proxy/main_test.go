package main

import (
	"bytes"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// startEchoServer accepts one connection and echoes everything back.
// Returns the address it's listening on.
func startEchoServer(t *testing.T) (addr string, stop func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("echo listen: %v", err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				io.Copy(c, c)
			}(c)
		}
	}()
	return ln.Addr().String(), func() { ln.Close() }
}

// startProxy starts the proxy serve loop in a goroutine.
func startProxy(t *testing.T, target string) (addr string, stop func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("proxy listen: %v", err)
	}
	go serve(ln, target)
	return ln.Addr().String(), func() { ln.Close() }
}

func TestProxyForwardsBidirectional(t *testing.T) {
	echoAddr, stopEcho := startEchoServer(t)
	defer stopEcho()
	proxyAddr, stopProxy := startProxy(t, echoAddr)
	defer stopProxy()

	conn, err := net.Dial("tcp", proxyAddr)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	payload := []byte("hello, zerotier\n")
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(buf, payload) {
		t.Errorf("got %q, want %q", buf, payload)
	}
}

// TestProxyHalfClose verifies the regression that motivated M1: when the client
// finishes sending and half-closes (CloseWrite), the proxy must let the server
// continue replying and forward those bytes back to the client. Naive io.Copy
// pairs that fully Close() on either direction's EOF will fail this.
func TestProxyHalfClose(t *testing.T) {
	// Server: reads everything from client until EOF, then sends a reply
	// and closes. Forces the proxy to handle client-side half-close.
	srvLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server listen: %v", err)
	}
	defer srvLn.Close()
	go func() {
		c, err := srvLn.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.Copy(io.Discard, c) // read until client half-closes
		c.Write([]byte("reply-after-half-close"))
	}()

	proxyAddr, stopProxy := startProxy(t, srvLn.Addr().String())
	defer stopProxy()

	conn, err := net.Dial("tcp", proxyAddr)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	if _, err := conn.Write([]byte("request-payload")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := conn.(*net.TCPConn).CloseWrite(); err != nil {
		t.Fatalf("close-write: %v", err)
	}

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	got, err := io.ReadAll(conn)
	if err != nil {
		t.Fatalf("read after half-close: %v", err)
	}
	if want := "reply-after-half-close"; string(got) != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestProxyHandlesMultipleConnections(t *testing.T) {
	echoAddr, stopEcho := startEchoServer(t)
	defer stopEcho()
	proxyAddr, stopProxy := startProxy(t, echoAddr)
	defer stopProxy()

	const n = 10
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			conn, err := net.Dial("tcp", proxyAddr)
			if err != nil {
				errs <- err
				return
			}
			defer conn.Close()
			msg := []byte{byte(i), byte(i + 1), byte(i + 2)}
			if _, err := conn.Write(msg); err != nil {
				errs <- err
				return
			}
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			buf := make([]byte, len(msg))
			if _, err := io.ReadFull(conn, buf); err != nil {
				errs <- err
				return
			}
			if !bytes.Equal(buf, msg) {
				errs <- &mismatchErr{got: buf, want: msg}
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}

type mismatchErr struct{ got, want []byte }

func (e *mismatchErr) Error() string { return "echo mismatch" }

func TestProxyTargetUnreachable(t *testing.T) {
	// 127.0.0.1:1 is virtually guaranteed to refuse connection.
	proxyAddr, stopProxy := startProxy(t, "127.0.0.1:1")
	defer stopProxy()

	conn, err := net.Dial("tcp", proxyAddr)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	// Proxy should accept and then immediately close without target.
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 1)
	_, err = conn.Read(buf)
	if err == nil {
		t.Errorf("expected EOF/error when target is unreachable, got data")
	}
}
