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
    const output_len = std.base64.url_safe_no_pad.Encoder.calcSize(input.len);
    const buffer = try allocator.alloc(u8, output_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(buffer, input);
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

test "authenticate" {
    const testing = std.testing;

    var auth: Auth = undefined;
    try auth.init(testing.allocator);
    defer auth.deinit();

    var req: HttpRequest = undefined;
    try req.init(testing.allocator);
    defer req.deinit();

    // Test 1: No auth header, no cookie -> .none
    const result1 = try auth.authenticate(&req);
    try testing.expectEqual(Authn.none, result1);

    // Test 2: Invalid bearer token (wrong format) -> .invalid
    try req.headers.put("authorization", "Basic invalid");
    const result2 = try auth.authenticate(&req);
    try testing.expectEqual(Authn.invalid, result2);

    // Test 3: Invalid bearer token (bad JWT format) -> .invalid
    try req.headers.put("authorization", "Bearer notvalidjwt");
    const result3 = try auth.authenticate(&req);
    try testing.expectEqual(Authn.invalid, result3);

    // Test 4: Invalid session (unknown sid) -> .invalid
    _ = req.headers.remove("authorization");
    try req.headers.put("cookie", "sid=unknown_sid");
    const result4 = try auth.authenticate(&req);
    try testing.expectEqual(Authn.invalid, result4);

    // Test 5: Expired session -> .invalid
    const now_ms = std.time.milliTimestamp();
    try auth.sessions.put("expired_sid", .{
        .principal = .{
            .user_id = "user123",
            .scheme = .session,
            .is_admin = false,
        },
        .expiry_at_ms = now_ms - 1000,
    });
    try req.headers.put("cookie", "sid=expired_sid");
    const result5 = try auth.authenticate(&req);
    try testing.expectEqual(Authn.invalid, result5);

    // Test 6: Valid session -> .principal
    try auth.sessions.put("valid_sid", .{
        .principal = .{
            .user_id = "user456",
            .scheme = .session,
            .is_admin = true,
        },
        .expiry_at_ms = now_ms + 3600000,
    });
    try req.headers.put("cookie", "sid=valid_sid");
    const result6 = try auth.authenticate(&req);
    try testing.expect(result6 == .principal);
    switch (result6) {
        .principal => |p| {
            try testing.expectEqualStrings("user456", p.user_id);
            try testing.expectEqual(AuthScheme.session, p.scheme);
            try testing.expect(p.is_admin);
        },
        else => unreachable,
    }

    // Test 7: Valid bearer token -> .principal
    _ = req.headers.remove("cookie");

    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const exp_ms = now_ms + 3600000; // 1 hour from now
    const payload_json = try std.fmt.allocPrint(testing.allocator, "{{\"sub\":\"user789\",\"admin\":true,\"iat\":{d},\"exp\":{d},\"iss\":\"zig-tcp\",\"aud\":\"zig-tcp-api\"}}", .{ now_ms, exp_ms });
    defer testing.allocator.free(payload_json);

    const header_b64 = try encodeBase64url(testing.allocator, header_json);
    defer testing.allocator.free(header_b64);
    const payload_b64 = try encodeBase64url(testing.allocator, payload_json);
    defer testing.allocator.free(payload_b64);

    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(auth.jwt_secret);
    hmac.update(header_b64);
    hmac.update(".");
    hmac.update(payload_b64);
    var signature: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    hmac.final(&signature);

    var sig_buf: [64]u8 = undefined;
    const signature_b64 = std.base64.url_safe_no_pad.Encoder.encode(&sig_buf, &signature);

    const jwt_token = try std.fmt.allocPrint(testing.allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature_b64 });
    defer testing.allocator.free(jwt_token);

    try req.headers.put("authorization", try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{jwt_token}));
    defer {
        if (req.headers.get("authorization")) |val| testing.allocator.free(val);
    }

    const result7 = try auth.authenticate(&req);
    try testing.expect(result7 == .principal);
    switch (result7) {
        .principal => |p| {
            try testing.expectEqualStrings("user789", p.user_id);
            try testing.expectEqual(AuthScheme.bearer, p.scheme);
            try testing.expect(p.is_admin);
        },
        .none => {
            return error.TestExpectedPrincipalButGotNone;
        },
        .invalid => {
            return error.TestExpectedPrincipalButGotInvalid;
        },
    }
}
