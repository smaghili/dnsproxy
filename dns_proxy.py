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

    async def resolve_domain_with_system_dns(self, domain):
        try:
            real_ip = socket.gethostbyname(domain)  # Resolve using system's default resolver
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

                if self.allow_all or any(domain in requested_domain_name for domain in self.whitelist):
                    # Return the local IP if allowed or whitelisted
                    reply_packet.add_answer(RR(question.qname, QTYPE.A, rdata=A(self.ip_address), ttl=60))
                else:
                    # First try to resolve with aiodns
                    resolved_ip = await self.resolve_domain(requested_domain_name)
                    if not resolved_ip:
                        # If aiodns fails, fallback to system DNS
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

class GracefulExit(SystemExit):
    pass

def raise_graceful_exit(*args):
    raise GracefulExit()

def handle_exit(loop, dns_server):
    async def shutdown():
        tasks = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        loop.stop()
        if dns_server:
            dns_server.stop_server()

    loop.create_task(shutdown())
    print("\nScript is stopping gracefully. Please wait...")

if __name__ == "__main__":
    loop = asyncio.get_event_loop()
    
    class ServerContainer:
        dns_server = None

    server_container = ServerContainer()

    async def run_main():
        parser = argparse.ArgumentParser(description='SNI Proxy with DNS')
        parser.add_argument('--dns-allow-all', action='store_true', help='Allow all DNS requests')
        parser.add_argument('--whitelist', type=str, help='Path to whitelist file')
        parser.add_argument('--ip', required=True, help='Server IP address')
        parser.add_argument('--port', type=int, default=53, help='DNS server port')
        args = parser.parse_args()

        whitelist = []
        if not args.dns_allow_all and args.whitelist:
            with open(args.whitelist, 'r') as f:
                whitelist = [line.strip() for line in f if line.strip()]

        server_container.dns_server = DNSServer(args.ip, allow_all=args.dns_allow_all, whitelist=whitelist, port=args.port)
        await server_container.dns_server.run_server()

    for sig in [signal.SIGINT, signal.SIGTERM]:
        loop.add_signal_handler(sig, lambda: handle_exit(loop, server_container.dns_server))

    try:
        loop.run_until_complete(run_main())
    except KeyboardInterrupt:
        print("Received keyboard interrupt.")
    except GracefulExit:
        print("Received signal to exit gracefully.")
    finally:
        print("Cleaning up...")
        loop.run_until_complete(loop.shutdown_asyncgens())
        loop.close()
        print("Script exited.")
    
    sys.exit(0)
