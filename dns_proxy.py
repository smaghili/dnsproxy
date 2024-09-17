import asyncio
import aiodns
from dnslib import DNSRecord, RR, A, QTYPE
import argparse
import signal
import socket

class DNSServer:
    def __init__(self, ip_address, allow_all=False, whitelist=None, port=53):
        self.ip_address = ip_address
        self.allow_all = allow_all
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

    async def handle_dns_request(self, data, addr):
        try:
            packet = DNSRecord.parse(data)
            for question in packet.questions:
                requested_domain_name = str(question.qname).rstrip('.')
                reply_packet = packet.reply()

                if self.allow_all or any(domain in requested_domain_name for domain in self.whitelist):
                    # Return the server IP for all domains when allow_all is True or domain is in whitelist
                    reply_packet.add_answer(RR(question.qname, QTYPE.A, rdata=A(self.ip_address), ttl=60))
                else:
                    # Resolve normally for non-whitelisted domains when not in allow_all mode
                    resolved_ip = await self.resolve_domain(requested_domain_name)
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

async def run_dns_server(ip_address, allow_all, whitelist, port):
    server = DNSServer(ip_address, allow_all=allow_all, whitelist=whitelist, port=port)
    await server.run_server()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='DNS Proxy Server')
    parser.add_argument('--ip', required=True, help='Server IP address')
    parser.add_argument('--port', type=int, default=53, help='DNS server port')
    parser.add_argument('--dns-allow-all', action='store_true', help='Allow all DNS requests')
    parser.add_argument('--whitelist', type=str, help='Path to whitelist file')
    args = parser.parse_args()

    whitelist = []
    if not args.dns_allow_all and args.whitelist:
        with open(args.whitelist, 'r') as f:
            whitelist = [line.strip() for line in f if line.strip()]

    asyncio.run(run_dns_server(args.ip, args.dns_allow_all, whitelist, args.port))
