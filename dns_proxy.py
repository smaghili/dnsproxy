import asyncio
import aiodns
from dnslib import DNSRecord, RR, A, QTYPE
import argparse
import signal
import socket

class DNSServer:
    def __init__(self, proxy_ip, whitelist=None, port=53):
        self.proxy_ip = proxy_ip
        self.whitelist = whitelist or []
        self.port = port
        self.resolver = None
        self.transport = None
        self.protocol = None

    async def init_resolver(self):
        self.resolver = aiodns.DNSResolver()

    async def resolve_domain(self, domain):
        try:
            result = await self.resolver.query(domain, 'A')
            return result[0].host
        except aiodns.error.DNSError:
            return None

    async def resolve_domain_with_system_dns(self, domain):
        try:
            real_ip = socket.gethostbyname(domain)
            return real_ip
        except Exception as e:
            print(f"Error resolving domain with system DNS {domain}: {e}")
            return None

    async def handle_dns_request(self, data, addr):
        try:
            packet = DNSRecord.parse(data)
            for question in packet.questions:
                requested_domain_name = str(question.qname).rstrip('.')
                reply_packet = packet.reply()

                if any(domain in requested_domain_name for domain in self.whitelist):
                    # Domain is in whitelist, return proxy IP
                    reply_packet.add_answer(RR(question.qname, QTYPE.A, rdata=A(self.proxy_ip), ttl=60))
                else:
                    # Domain is not in whitelist, resolve using system DNS (Google DNS)
                    resolved_ip = await self.resolve_domain_with_system_dns(requested_domain_name)
                    
                    if resolved_ip:
                        reply_packet.add_answer(RR(question.qname, QTYPE.A, rdata=A(resolved_ip), ttl=60))
                    else:
                        print(f"Failed to resolve domain: {requested_domain_name}")
                        return None

                return reply_packet.pack()
        except Exception as e:
            print(f"Error handling DNS request: {e}")
            return None

    async def run_server(self):
        await self.init_resolver()

        class DNSProtocol(asyncio.DatagramProtocol):
            def __init__(self, dns_server):
                self.dns_server = dns_server

            def connection_made(self, transport):
                self.transport = transport
                self.dns_server.transport = transport

            def datagram_received(self, data, addr):
                asyncio.create_task(self.process_request(data, addr))

            async def process_request(self, data, addr):
                response = await self.dns_server.handle_dns_request(data, addr)
                if response:
                    self.transport.sendto(response, addr)

        loop = asyncio.get_running_loop()
        self.transport, self.protocol = await loop.create_datagram_endpoint(
            lambda: DNSProtocol(self),
            local_addr=('0.0.0.0', self.port)
        )

        print(f"DNS server started on port {self.port} and is running in the background.")
        print(f"Proxy IP: {self.proxy_ip}")
        print(f"Whitelisted domains: {', '.join(self.whitelist)}")

        try:
            await asyncio.Future()  # Run forever
        except asyncio.CancelledError:
            print("DNS server is shutting down...")
        finally:
            self.stop_server()

    def stop_server(self):
        if self.transport:
            self.transport.close()
        print("DNS server stopped.")

async def run_dns_server(proxy_ip, whitelist, port):
    server = DNSServer(proxy_ip, whitelist=whitelist, port=port)
    await server.run_server()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='DNS Proxy Server')
    parser.add_argument('--ip', required=True, help='Proxy IP address')
    parser.add_argument('--port', type=int, default=53, help='DNS server port')
    parser.add_argument('--whitelist', type=str, help='Path to whitelist file')
    args = parser.parse_args()

    whitelist = []
    if args.whitelist:
        with open(args.whitelist, 'r') as f:
            whitelist = [line.strip() for line in f if line.strip()]

    asyncio.run(run_dns_server(args.ip, whitelist, args.port))
