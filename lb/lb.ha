use fmt;
use net::ip;
use rt;
use unix::signal;

def LISTEN_PORT: u16 = 9999;
def BACKEND_PORT: u16 = 8080;
def BACKLOG: u32 = 16384;

def MAX_PAIRS: size = 512;
def REQ_BUF_SIZE: size = 2048;
def RESP_BUF_SIZE: size = 512;
def EVENTS_CAP: int = 256;

def TCP_NODELAY: int = 1;
def TCP_DEFER_ACCEPT: int = 9;

const API1_ADDR: ip::addr4 = [172, 30, 0, 11];
const API2_ADDR: ip::addr4 = [172, 30, 0, 12];

type cstate = enum u8 {
	FREE = 0,
	BK_CONNECTING,
	READ_REQ,
	WRITE_REQ,
	READ_RESP,
	WRITE_RESP,
};

type pair = struct {
	state: cstate,
	backend_idx: u8,
	client_fd: int,
	backend_fd: int,
	req_used: size,
	req_total: size,
	req_pos: size,
	resp_used: size,
	resp_total: size,
	resp_pos: size,
	req_buf: [REQ_BUF_SIZE]u8,
	resp_buf: [RESP_BUF_SIZE]u8,
};

let pool: [MAX_PAIRS]pair = [pair {
	state = cstate::FREE,
	backend_idx = 0,
	client_fd = -1,
	backend_fd = -1,
	req_used = 0, req_total = 0, req_pos = 0,
	resp_used = 0, resp_total = 0, resp_pos = 0,
	req_buf = [0...],
	resp_buf = [0...],
}...];

let free_stack: [MAX_PAIRS]u32 = [0...];
let free_top: size = 0;
let epfd: int = -1;
let listener_fd: int = -1;
let next_backend: u8 = 0;

def KEY_LISTENER: u32 = 0xFFFFFFFF;
def ET_EVENTS: u32 = rt::EPOLLIN | rt::EPOLLOUT | rt::EPOLLRDHUP | rt::EPOLLET;

fn key_client(idx: size) u32 = ((idx << 1) | 0): u32;
fn key_backend(idx: size) u32 = ((idx << 1) | 1): u32;
fn key_idx(k: u32) size = (k >> 1): size;
fn key_is_backend(k: u32) bool = (k & 1) == 1;

fn alloc_pair() (size | void) = {
	if (free_top == 0) {
		return void;
	};
	free_top -= 1;
	return free_stack[free_top]: size;
};

fn release_pair(idx: size) void = {
	let p = &pool[idx];
	if (p.state == cstate::FREE) return;
	if (p.client_fd >= 0) {
		rt::close(p.client_fd): void;
		p.client_fd = -1;
	};
	if (p.backend_fd >= 0) {
		rt::close(p.backend_fd): void;
		p.backend_fd = -1;
	};
	p.state = cstate::FREE;
	p.req_used = 0; p.req_total = 0; p.req_pos = 0;
	p.resp_used = 0; p.resp_total = 0; p.resp_pos = 0;
	free_stack[free_top] = idx: u32;
	free_top += 1;
};

fn set_sockopt_int(fd: int, level: int, opt: int, val: int) void = {
	let v = val;
	match (rt::setsockopt(fd, level, opt, &v: *opaque, size(int): u32)) {
	case int => void;
	case rt::errno => void;
	};
};

fn set_nodelay(fd: int) void = {
	set_sockopt_int(fd, rt::IPPROTO_TCP, TCP_NODELAY, 1);
};

fn epoll_add(fd: int, events: u32, key: u32) bool = {
	let ev = rt::epoll_event {
		events = events,
		data = rt::epoll_data { u32_ = key },
	};
	match (rt::epoll_ctl(epfd, rt::EPOLL_CTL_ADD, fd, &ev)) {
	case void => return true;
	case rt::errno => return false;
	};
};

fn header_end(buf: []u8, used: size) (size | void) = {
	if (used < 4) return void;
	let limit = used - 3;
	for (let i: size = 0; i < limit; i += 1) {
		if (buf[i] == 13 && buf[i + 1] == 10
				&& buf[i + 2] == 13 && buf[i + 3] == 10) {
			return i + 4;
		};
	};
};

fn content_length(buf: []u8, header_len: size) size = {
	const tag: [15]u8 = ['c', 'o', 'n', 't', 'e', 'n', 't', '-',
		'l', 'e', 'n', 'g', 't', 'h', ':'];
	if (header_len < 17) return 0;
	let limit = header_len - 16;
	let i: size = 0;
	for (i < limit; i += 1) {
		if (buf[i] != 13 && i != 0) continue;
		let off: size = if (i == 0) 0 else i + 2;
		if (off + 15 > header_len) break;
		let m = true;
		for (let k: size = 0; k < 15; k += 1) {
			let c = buf[off + k];
			if (c >= 'A' && c <= 'Z') c |= 0x20;
			if (c != tag[k]) { m = false; break; };
		};
		if (!m) continue;
		let p = off + 15;
		for (p < header_len && (buf[p] == ' ' || buf[p] == '\t'); p += 1) void;
		let n: size = 0;
		for (p < header_len && buf[p] >= '0' && buf[p] <= '9'; p += 1) {
			n = n * 10 + (buf[p] - '0'): size;
		};
		return n;
	};
	return 0;
};

fn try_parse_http(buf: []u8, used: size) (size | void) = {
	match (header_end(buf, used)) {
	case let h: size =>
		return h + content_length(buf, h);
	case void => return void;
	};
};

fn open_backend_nonblock(addr: ip::addr4) (int | void) = {
	let sock_type = rt::SOCK_STREAM | rt::SOCK_NONBLOCK | rt::SOCK_CLOEXEC;
	const fd = match (rt::socket(rt::AF_INET: int, sock_type, 0)) {
	case let f: int => yield f;
	case rt::errno => return void;
	};
	set_nodelay(fd);
	let sa = ip::to_native(addr, BACKEND_PORT);
	match (rt::connect(fd, &sa, size(rt::sockaddr): u32)) {
	case void => void;
	case let e: rt::errno =>
		if (e != rt::EINPROGRESS && e != rt::EAGAIN) {
			rt::close(fd): void;
			return void;
		};
	};
	return fd;
};

fn drive_write(fd: int, buf: []u8, pos: size, total: size) (size | void) = {
	for (pos < total) {
		match (rt::write(fd, &buf[pos]: *opaque, total - pos)) {
		case let n: size =>
			if (n == 0) return void;
			pos += n;
		case let e: rt::errno =>
			if (e == rt::EAGAIN || e == rt::EINTR) return pos;
			return void;
		};
	};
	return pos;
};

fn drive_read(fd: int, buf: []u8, used: size) (size | void) = {
	for (used < len(buf)) {
		match (rt::read(fd, &buf[used]: *opaque, len(buf) - used)) {
		case let n: size =>
			if (n == 0) return void;
			used += n;
		case let e: rt::errno =>
			if (e == rt::EAGAIN) return used;
			if (e == rt::EINTR) continue;
			return void;
		};
	};
	return used;
};

fn handle_listener() void = {
	for (true) {
		const cfd = match (rt::accept4(listener_fd, null, null,
				rt::SOCK_NONBLOCK | rt::SOCK_CLOEXEC)) {
		case let fd: int => yield fd;
		case let e: rt::errno =>
			if (e == rt::EAGAIN || e == rt::EINTR) return;
			return;
		};
		set_nodelay(cfd);

		const idx = match (alloc_pair()) {
		case let i: size => yield i;
		case void =>
			rt::close(cfd): void;
			continue;
		};

		let p = &pool[idx];
		p.client_fd = cfd;
		p.req_used = 0; p.req_total = 0; p.req_pos = 0;
		p.resp_used = 0; p.resp_total = 0; p.resp_pos = 0;
		p.backend_idx = next_backend;
		next_backend ^= 1;

		let baddr = if (p.backend_idx == 0) API1_ADDR else API2_ADDR;
		const bfd = match (open_backend_nonblock(baddr)) {
		case let f: int => yield f;
		case void =>
			rt::close(cfd): void;
			p.client_fd = -1;
			free_stack[free_top] = idx: u32;
			free_top += 1;
			continue;
		};
		p.backend_fd = bfd;
		p.state = cstate::BK_CONNECTING;

		// Register both fds once with edge-triggered events.
		// No further epoll_ctl calls are needed for state transitions.
		if (!epoll_add(cfd, ET_EVENTS, key_client(idx))) {
			release_pair(idx);
			continue;
		};
		if (!epoll_add(bfd, ET_EVENTS, key_backend(idx))) {
			release_pair(idx);
			continue;
		};
	};
};

fn try_write_req(p: *pair, idx: size) void = {
	match (drive_write(p.backend_fd, p.req_buf[..p.req_total], p.req_pos,
			p.req_total)) {
	case let pos: size =>
		p.req_pos = pos;
		if (pos == p.req_total) {
			p.state = cstate::READ_RESP;
			p.resp_used = 0; p.resp_total = 0;
			try_read_resp(p, idx);
		};
	case void =>
		release_pair(idx);
	};
};

fn try_read_resp(p: *pair, idx: size) void = {
	match (drive_read(p.backend_fd, p.resp_buf[..], p.resp_used)) {
	case let used: size =>
		p.resp_used = used;
		if (p.resp_total == 0) {
			match (try_parse_http(p.resp_buf[..], used)) {
			case let total: size =>
				p.resp_total = total;
				if (total > len(p.resp_buf)) {
					release_pair(idx);
					return;
				};
			case void => void;
			};
		};
		if (p.resp_total > 0 && p.resp_used >= p.resp_total) {
			p.state = cstate::WRITE_RESP;
			p.resp_pos = 0;
			try_write_resp(p, idx);
		};
	case void =>
		release_pair(idx);
	};
};

fn try_write_resp(p: *pair, idx: size) void = {
	match (drive_write(p.client_fd, p.resp_buf[..p.resp_total], p.resp_pos,
			p.resp_total)) {
	case let pos: size =>
		p.resp_pos = pos;
		if (pos == p.resp_total) {
			let leftover: size = 0;
			if (p.req_used > p.req_total) {
				leftover = p.req_used - p.req_total;
				let src = p.req_buf[p.req_total..p.req_used];
				let dst = p.req_buf[..leftover];
				for (let i: size = 0; i < leftover; i += 1) {
					dst[i] = src[i];
				};
			};
			p.req_used = leftover;
			p.req_total = 0;
			p.req_pos = 0;
			p.resp_used = 0;
			p.resp_total = 0;
			p.resp_pos = 0;
			p.state = cstate::READ_REQ;
			if (leftover > 0) {
				try_read_req(p, idx);
			} else {
				// Proactively read any data already buffered
				// (likely none, but safe with edge-triggered).
				try_read_req(p, idx);
			};
		};
	case void =>
		release_pair(idx);
	};
};

fn try_read_req(p: *pair, idx: size) void = {
	match (drive_read(p.client_fd, p.req_buf[..], p.req_used)) {
	case let used: size =>
		p.req_used = used;
		if (p.req_total == 0) {
			match (try_parse_http(p.req_buf[..], used)) {
			case let total: size =>
				p.req_total = total;
				if (total > len(p.req_buf)) {
					release_pair(idx);
					return;
				};
			case void => void;
			};
		};
		if (p.req_total > 0 && p.req_used >= p.req_total) {
			p.state = cstate::WRITE_REQ;
			p.req_pos = 0;
			try_write_req(p, idx);
		};
	case void =>
		release_pair(idx);
	};
};

fn handle_pair(idx: size, side_backend: bool, events: u32) void = {
	let p = &pool[idx];
	if (p.state == cstate::FREE) return;

	if (events & (rt::EPOLLERR | rt::EPOLLHUP) != 0) {
		release_pair(idx);
		return;
	};

	switch (p.state) {
	case cstate::BK_CONNECTING =>
		if (!side_backend) {
			if (events & rt::EPOLLRDHUP != 0) release_pair(idx);
			return;
		};
		if (events & rt::EPOLLOUT == 0) {
			if (events & rt::EPOLLRDHUP != 0) release_pair(idx);
			return;
		};
		let so_err: int = 0;
		let sl: u32 = size(int): u32;
		match (rt::getsockopt(p.backend_fd, rt::SOL_SOCKET,
				rt::SO_ERROR, &so_err: *opaque, &sl)) {
		case int =>
			if (so_err != 0) {
				release_pair(idx);
				return;
			};
		case rt::errno =>
			release_pair(idx);
			return;
		};
		p.state = cstate::READ_REQ;
		// Drain any data the client may have already sent while we
		// were waiting for the backend connect to complete.
		try_read_req(p, idx);
	case cstate::READ_REQ =>
		if (side_backend) {
			if (events & rt::EPOLLRDHUP != 0) {
				release_pair(idx);
			};
			return;
		};
		if (events & rt::EPOLLIN != 0) {
			try_read_req(p, idx);
		} else if (events & rt::EPOLLRDHUP != 0) {
			release_pair(idx);
		};
	case cstate::WRITE_REQ =>
		if (!side_backend) {
			if (events & rt::EPOLLRDHUP != 0) {
				release_pair(idx);
			};
			return;
		};
		if (events & rt::EPOLLOUT != 0) {
			try_write_req(p, idx);
		} else if (events & rt::EPOLLRDHUP != 0) {
			release_pair(idx);
		};
	case cstate::READ_RESP =>
		if (!side_backend) {
			if (events & rt::EPOLLRDHUP != 0) {
				release_pair(idx);
			};
			return;
		};
		if (events & rt::EPOLLIN != 0) {
			try_read_resp(p, idx);
		} else if (events & rt::EPOLLRDHUP != 0) {
			release_pair(idx);
		};
	case cstate::WRITE_RESP =>
		if (side_backend) {
			if (events & rt::EPOLLRDHUP != 0) {
				release_pair(idx);
			};
			return;
		};
		if (events & rt::EPOLLOUT != 0) {
			try_write_resp(p, idx);
		} else if (events & rt::EPOLLRDHUP != 0) {
			release_pair(idx);
		};
	case => void;
	};
};

fn run() void = {
	let events: [EVENTS_CAP]rt::epoll_event = [rt::epoll_event {
		events = 0,
		data = rt::epoll_data { u32_ = 0 },
	}...];

	for (true) {
		const n = match (rt::epoll_wait(epfd, &events[0],
				EVENTS_CAP, -1)) {
		case let r: int => yield r;
		case let e: rt::errno =>
			if (e == rt::EINTR) continue;
			fmt::fatal("epoll_wait failed");
		};
		for (let i: int = 0; i < n; i += 1) {
			let ev = events[i];
			let key = ev.data.u32_;
			if (key == KEY_LISTENER) {
				handle_listener();
			} else {
				handle_pair(key_idx(key),
					key_is_backend(key), ev.events);
			};
		};
	};
};

export fn main() void = {
	signal::ignore(signal::sig::PIPE);

	for (let i: size = 0; i < MAX_PAIRS; i += 1) {
		free_stack[i] = (MAX_PAIRS - 1 - i): u32;
	};
	free_top = MAX_PAIRS;

	let lfd = match (rt::socket(rt::AF_INET: int,
			rt::SOCK_STREAM | rt::SOCK_NONBLOCK | rt::SOCK_CLOEXEC,
			0)) {
	case let f: int => yield f;
	case let e: rt::errno => fmt::fatal("socket: ", rt::strerror(e));
	};
	listener_fd = lfd;

	set_sockopt_int(lfd, rt::SOL_SOCKET, rt::SO_REUSEADDR, 1);
	set_sockopt_int(lfd, rt::SOL_SOCKET, rt::SO_REUSEPORT, 1);
	set_nodelay(lfd);
	// TCP_DEFER_ACCEPT: kernel only returns from accept() once data has
	// arrived, fusing the TCP handshake with the first request and
	// removing one epoll wakeup per new connection.
	set_sockopt_int(lfd, rt::IPPROTO_TCP, TCP_DEFER_ACCEPT, 1);

	let sa = ip::to_native(ip::ANY_V4: ip::addr, LISTEN_PORT);
	match (rt::bind(lfd, &sa, size(rt::sockaddr): u32)) {
	case void => void;
	case let e: rt::errno => fmt::fatal("bind: ", rt::strerror(e));
	};
	match (rt::listen(lfd, BACKLOG)) {
	case int => void;
	case let e: rt::errno => fmt::fatal("listen: ", rt::strerror(e));
	};

	epfd = match (rt::epoll_create1(rt::EPOLL_CLOEXEC)) {
	case let f: int => yield f;
	case let e: rt::errno => fmt::fatal("epoll_create1: ", rt::strerror(e));
	};
	if (!epoll_add(lfd, rt::EPOLLIN, KEY_LISTENER)) {
		fmt::fatal("epoll_ctl(listener)");
	};

	run();
};
