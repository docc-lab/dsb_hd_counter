package registry

import (
	"fmt"
	"net"
	"os"
	"time"

	consul "github.com/hashicorp/consul/api"
	"github.com/rs/zerolog/log"
)

// NewClient returns a new Client with connection to consul
func NewClient(addr string) (*Client, error) {
	cfg := consul.DefaultConfig()
	cfg.Address = addr

	var c *consul.Client
	var err error
	
	// Retry connection to Consul with backoff
	for i := 0; i < 5; i++ {
		c, err = consul.NewClient(cfg)
		if err == nil {
			// Test the connection
			_, err = c.Status().Leader()
			if err == nil {
				log.Info().Msgf("Successfully connected to Consul at %s", addr)
				return &Client{c}, nil
			}
		}
		
		log.Error().Msgf("Failed to connect to Consul (attempt %d/5): %v", i+1, err)
		if i < 4 {
			time.Sleep(time.Duration(i+1) * 2 * time.Second)
		}
	}

	return nil, fmt.Errorf("failed to connect to Consul after 5 attempts: %v", err)
}

// Client provides an interface for communicating with registry
type Client struct {
	*consul.Client
}

// Look for the network device being dedicated for gRPC traffic.
// The network CDIR should be specified in os environment
// "DSB_HOTELRESERV_GRPC_NETWORK".
// If not found, return the first non loopback IP address.
func getLocalIP() (string, error) {
	var ipGrpc string
	var ips []net.IP

	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "", err
	}
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				ips = append(ips, ipnet.IP)
			}
		}
	}
	if len(ips) == 0 {
		return "", fmt.Errorf("registry: can not find local ip")
	} else if len(ips) > 1 {
		// by default, return the first network IP address found.
		ipGrpc = ips[0].String()

		grpcNet := os.Getenv("DSB_GRPC_NETWORK")
		_, ipNetGrpc, err := net.ParseCIDR(grpcNet)
		if err != nil {
			log.Error().Msgf("An invalid network CIDR is set in environment DSB_HOTELRESERV_GRPC_NETWORK: %v", grpcNet)
		} else {
			for _, ip := range ips {
				if ipNetGrpc.Contains(ip) {
					ipGrpc = ip.String()
					log.Info().Msgf("gRPC traffic is routed to the dedicated network %s", ipGrpc)
					break
				}
			}
		}
	} else {
		// only one network device existed
		ipGrpc = ips[0].String()
	}

	return ipGrpc, nil
}

// Register a service with registry
func (c *Client) Register(name string, id string, ip string, port int) error {
	if ip == "" {
		var err error
		ip, err = getLocalIP()
		if err != nil {
			return err
		}
	}
	
	// Register without health checks to prevent automatic deregistration
	// Health checks were causing services to be deregistered due to network connectivity issues
	reg := &consul.AgentServiceRegistration{
		ID:      id,
		Name:    name,
		Port:    port,
		Address: ip,
		// No health check - services will stay registered until manually deregistered
	}
	
	log.Info().Msgf("Trying to register service [ name: %s, id: %s, address: %s:%d ]", name, id, ip, port)
	
	// Retry registration with backoff
	for i := 0; i < 3; i++ {
		err := c.Agent().ServiceRegister(reg)
		if err == nil {
			log.Info().Msgf("Successfully registered service [ name: %s, id: %s ]", name, id)
			return nil
		}
		log.Error().Msgf("Failed to register service (attempt %d/3): %v", i+1, err)
		if i < 2 {
			time.Sleep(time.Duration(i+1) * time.Second)
		}
	}
	
	return fmt.Errorf("failed to register service after 3 attempts")
}

// Deregister removes the service address from registry
func (c *Client) Deregister(id string) error {
	return c.Agent().ServiceDeregister(id)
}
