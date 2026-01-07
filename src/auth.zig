const std = @import("std");
const HttpRequest = @import("http_request.zig");

const AuthScheme = enum { bearer, session };

const Principal = struct {
    user_id: []const u8,
    scheme: AuthScheme,
    is_admin: bool = false,
};

pub const AuthPolicy = union(enum) {
    public,
    any_authenticated,
    bearer_only,
    session_only,
    admin_only,
};

pub const Authz = union(enum) {
    forbidden,
    unauthorized,
    allow: ?Principal,
};

const Authn = union(enum) {
    none, // no Authorization header + no cookie
    invalid, // header/cookie present but invalid
    principal: Principal,
};

fn parseBearer(value: []const u8) ?[]const u8 {
    // token: "Bearer ..."
    const stripped = std.mem.trim(u8, value, " \t");
    const prefix = "Bearer ";

    if (stripped.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(stripped[0..prefix.len], prefix)) return null;

    const token = std.mem.trim(u8, stripped[prefix.len..], " \t");
    if (token.len == 0) return null;

    return token;
}

pub const Auth = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    // sid: sid -> Principal + expiry
    sessions: std.StringHashMap(Session),
    sessions_mu: std.Thread.Mutex,

    jwt_secret: []const u8,

    pub fn init(self: *Auth, allocator: std.mem.Allocator) !void {
        self.arena = .init(allocator);
        const a = self.arena.allocator();

        self.allocator = a;
        self.sessions = .init(a);
        self.sessions_mu = .{};
        self.jwt_secret = "secret";
    }

    pub fn deinit(self: *Auth) void {
        self.sessions.deinit();
        self.arena.deinit();
    }

    pub fn authenticate(self: *Auth, req: *const HttpRequest) !Authn {
        // try Authorization: Bearer tokens first
        // fallback to sid (cookie)

        // prioritize authorization header
        if (req.getHeader("authorization")) |auth_token| {
            const token = parseBearer(auth_token) orelse return .invalid;
            var parts = std.mem.splitScalar(u8, token, '.');

            const header_b64 = parts.first();
            // const header_json = decodeBase64url(self.allocator, header_b64) catch return .invalid;

            const payload_b64 = parts.next() orelse return .invalid;
            const payload_json = decodeBase64url(req.allocator, payload_b64) catch return .invalid;
            defer self.allocator.free(payload_json);

            const signature_b64 = parts.next() orelse return .invalid;
            // const signature = decodeBase64url(self.allocator, signature_b64) catch return .invalid;

            var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(self.jwt_secret);
            hmac.update(header_b64);
            hmac.update(".");
            hmac.update(payload_b64);

            var computed_digest: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
            hmac.final(&computed_digest);

            const encoder = std.base64.url_safe_no_pad.Encoder;

            var computed_sig_buf: [64]u8 = undefined;
            const computed_sig_str = encoder.encode(&computed_sig_buf, &computed_digest);

            if (!std.mem.eql(u8, signature_b64, computed_sig_str)) return .invalid;

            const claims_parsed = parseJwtClaims(req.allocator, payload_json) catch return .invalid;
            const claims = claims_parsed.value;
            defer claims_parsed.deinit();

            // validate exp (+ small clock skew)
            if (std.time.milliTimestamp() > claims.exp) return .invalid;

            // optional iss/aud checks
            // if (!issOk || !audOk) return .invalid;

            const user_id = try self.allocator.dupe(u8, claims.sub);
            errdefer self.allocator.free(user_id);

            return .{
                .principal = .{
                    .user_id = user_id,
                    .scheme = .bearer,
                    .is_admin = claims.admin,
                },
            };
        }

        // cookie fallbback: sid
        if (req.getCookie("sid")) |sid| {
            const now_ms = std.time.milliTimestamp();

            self.sessions_mu.lock();
            defer self.sessions_mu.unlock();

            if (self.sessions.get(sid)) |session| {
                if (now_ms >= session.expiry_at_ms) {
                    _ = self.sessions.remove(sid);
                    return .invalid;
                }
                return .{ .principal = session.principal };
            }

            return .invalid;
        }

        return .none;
    }

    pub fn authorize(self: *Auth, policy: AuthPolicy, authn: Authn) !Authz {
        _ = self;

        switch (policy) {
            .public => return .{ .allow = null },
            .any_authenticated => return switch (authn) {
                .principal => |p| .{ .allow = p },
                .none, .invalid => .unauthorized,
            },

            .bearer_only => return switch (authn) {
                .principal => |p| if (p.scheme == .bearer) .{ .allow = p } else .forbidden,
                .none, .invalid => .unauthorized,
            },

            .session_only => return switch (authn) {
                .principal => |p| if (p.scheme == .session) .{ .allow = p } else .forbidden,
                .none, .invalid => .unauthorized,
            },

            .admin_only => return switch (authn) {
                .principal => |p| if (p.is_admin) .{ .allow = p } else .forbidden,
                .none, .invalid => .unauthorized,
            },
        }
    }
};

const Session = struct {
    principal: Principal,
    expiry_at_ms: i64,
};

fn decodeBase64url(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    const Base64 = std.base64.url_safe_no_pad;
    const Decoder = Base64.Decoder;

    const max_len = try Decoder.calcSizeForSlice(encoded);
    const decoded_buffer = try allocator.alloc(u8, max_len);

    try Decoder.decode(decoded_buffer, encoded);

    return decoded_buffer;
}

fn encodeBase64url(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const output_len = encoder.calcSize(input.len);

    var buffer = try allocator.alloc(u8, output_len);
    _ = encoder.encode(&buffer, input);

    return buffer;
}

fn sha256Hash(input: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &hash, .{});

    return hash;
}

const Claim = struct {
    sub: []const u8,
    admin: bool,
    iat: u64,
    exp: u64,
    iss: []const u8,
    aud: []const u8,
};

/// Parse Jwt payload
/// Example claim
/// {
///     sub: user-123,
///     admin: true,
///     iat: 1700000000,
///     exp: 1700000900,
///     iss: zig-tcp,
///     aud: zig-tcp-api
/// }
fn parseJwtClaims(allocator: std.mem.Allocator, claims: []const u8) !std.json.Parsed(Claim) {
    const parsed = try std.json.parseFromSlice(
        Claim,
        allocator,
        claims,
        .{ .ignore_unknown_fields = true },
    );

    return parsed;
}
