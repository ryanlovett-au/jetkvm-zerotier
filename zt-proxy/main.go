// zt-proxy: binds to a specific IP:port and forwards TCP to another address.
// Used to expose JetKVM WebUI only on the ZeroTier interface.
package main

import (
	"errors"
	"flag"
	"io"
	"log"
	"net"
)

func main() {
	listen := flag.String("listen", "", "Address to listen on, e.g. 10.x.x.x:80 (required)")
	target := flag.String("target", "127.0.0.1:80", "Address to forward to")
	flag.Parse()

	if *listen == "" {
		log.Fatal("Usage: zt-proxy -listen <IP:port> [-target <IP:port>]")
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("Failed to listen on %s: %v", *listen, err)
	}
	log.Printf("zt-proxy: %s -> %s", *listen, *target)

	serve(ln, *target)
}

func serve(ln net.Listener, target string) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("Accept error: %v", err)
			continue
		}
		go handle(conn, target)
	}
}

func handle(src net.Conn, target string) {
	defer src.Close()
	dst, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("Failed to connect to %s: %v", target, err)
		return
	}
	defer dst.Close()

	done := make(chan struct{}, 2)
	go func() {
		io.Copy(dst, src)
		closeWrite(dst)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(src, dst)
		closeWrite(src)
		done <- struct{}{}
	}()
	<-done
	<-done
}

// closeWrite half-closes the write side if the connection supports it,
// so the peer sees EOF without tearing down the read side.
func closeWrite(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
	}
}
