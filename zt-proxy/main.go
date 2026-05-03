// zt-proxy: binds to a specific IP:port and forwards TCP to another address.
// Used to expose JetKVM WebUI only on the ZeroTier interface.
package main

import (
	"flag"
	"io"
	"log"
	"net"
)

func main() {
	listen := flag.String("listen", "10.107.107.245:80", "Address to listen on (ZeroTier IP:port)")
	target := flag.String("target", "127.0.0.1:80", "Address to forward to")
	flag.Parse()

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("Failed to listen on %s: %v", *listen, err)
	}
	log.Printf("zt-proxy: %s -> %s", *listen, *target)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("Accept error: %v", err)
			continue
		}
		go handle(conn, *target)
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
	go func() { io.Copy(dst, src); done <- struct{}{} }()
	go func() { io.Copy(src, dst); done <- struct{}{} }()
	<-done
}
