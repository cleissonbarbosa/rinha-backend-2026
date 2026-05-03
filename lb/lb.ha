use fmt;
use io;
use net;
use net::ip;
use net::tcp;
use os;
use rt;
use strconv;
use strings;
use unix::signal;

def LISTEN_PORT: u16 = 9999;
def BACKEND_PORT: u16 = 8080;
def API1_ADDR: ip::addr4 = [172, 30, 0, 11];
def API2_ADDR: ip::addr4 = [172, 30, 0, 12];
def BACKLOG: tcp::backlog = 8192;
def BUFFER_SIZE: size = 65536;

fn header_end(buf: []u8, used: size) (size | void) = {
	if (used < 4) {
		return void;
	};

	let limit = used - 3;
	let i: size = 0;
	for (i < limit; i += 1) {
		if (buf[i] == 13 && buf[i + 1] == 10 &&
				buf[i + 2] == 13 && buf[i + 3] == 10) {
			return i + 4;
		};
	};
};

fn content_length(buf: []u8, header_len: size) size = {
	let header = strings::fromutf8_unsafe(buf[..header_len]);
	let (_, rest) = strings::cut(header, "Content-Length:");
	if (rest == "") {
		return 0;
	};

	let (raw, _) = strings::cut(rest, "\r\n");
	let value = strings::trim(raw, ' ', '\t');

	match (strconv::stou(value)) {
	case let n: uint =>
		return n: size;
	case =>
		return 0;
	};
};

fn read_http(sock: net::socket, buf: []u8) (size | void) = {
	let used: size = 0;

	for (true) {
		match (io::read(sock, buf[used..])) {
		case let n: size =>
			if (n == 0) {
				return void;
			};
			used += n;
		case io::EOF =>
			return void;
		case io::error =>
			return void;
		};

		match (header_end(buf, used)) {
		case let h: size =>
			let total = h + content_length(buf, h);
			if (total > len(buf)) {
				return void;
			};
			if (used >= total) {
				return total;
			};
		case void =>
			if (used == len(buf)) {
				return void;
			};
		};
	};
};

fn write_http(sock: net::socket, buf: []u8) bool = {
	match (io::writeall(sock, buf)) {
	case size =>
		return true;
	case io::error =>
		return false;
	};
};

fn connect_backend(addr: ip::addr4) (net::socket | void) = {
	match (tcp::connect(addr, BACKEND_PORT)) {
	case let s: net::socket =>
		return s;
	case net::error =>
		return void;
	};
};

fn close_socket(sock: net::socket) void = {
	match (net::close(sock)) {
	case void => void;
	case net::error => void;
	};
};

fn serve_client(client: net::socket, next: bool) void = {
	let api1 = match (connect_backend(API1_ADDR)) {
	case let s: net::socket => yield s;
	case void =>
		return;
	};
	let api2 = match (connect_backend(API2_ADDR)) {
	case let s: net::socket => yield s;
	case void =>
		close_socket(api1);
		return;
	};

	let req: [BUFFER_SIZE]u8 = [0...];
	let resp: [BUFFER_SIZE]u8 = [0...];

	for (true) {
		let req_len = match (read_http(client, req[..])) {
		case let n: size => yield n;
		case void => break;
		};

		let upstream = if (next) api2 else api1;
		next = !next;

		if (!write_http(upstream, req[..req_len])) {
			break;
		};

		let resp_len = match (read_http(upstream, resp[..])) {
		case let n: size => yield n;
		case void => break;
		};

		if (!write_http(client, resp[..resp_len])) {
			break;
		};
	};

	close_socket(api1);
	close_socket(api2);
	close_socket(client);
};

export fn main() void = {
	signal::ignore(signal::sig::CHLD);
	signal::ignore(signal::sig::PIPE);

	let listener = match (tcp::listen(ip::ANY_V4, LISTEN_PORT,
			tcp::reuseaddr, tcp::reuseport, BACKLOG)) {
	case let s: net::socket =>
		yield s;
	case let err: net::error =>
		fmt::fatal("listen: ", net::strerror(err));
	};

	let next = false;
	for (true) {
		let client = match (tcp::accept(listener)) {
		case let s: net::socket =>
			yield s;
		case net::error =>
			continue;
		};

		let start = next;
		next = !next;
		match (rt::fork()) {
		case let pid: rt::pid_t =>
			close_socket(client);
		case void =>
			close_socket(listener);
			serve_client(client, start);
			os::exit(0);
		case rt::errno =>
			close_socket(client);
		};
	};
};
