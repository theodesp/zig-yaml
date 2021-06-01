const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.parse);
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const TokenIndex = Tokenizer.TokenIndex;
const TokenIterator = Tokenizer.TokenIterator;

pub const Node = struct {
    tag: Tag,
    tree: *const Tree,

    pub const Tag = enum {
        root,
        doc,
        map,
        value,
    };

    pub fn cast(self: *Node, comptime T: type) ?*T {
        if (self.tag != T.base_tag) {
            return null;
        }
        return @fieldParentPtr(T, "base", self);
    }

    pub fn deinit(self: *Node, allocator: *Allocator) void {
        switch (self.tag) {
            .root => @fieldParentPtr(Node.Root, "base", self).deinit(allocator),
            .doc => @fieldParentPtr(Node.Doc, "base", self).deinit(allocator),
            .map => @fieldParentPtr(Node.Map, "base", self).deinit(allocator),
            .value => @fieldParentPtr(Node.Value, "base", self).deinit(allocator),
        }
    }

    pub fn format(
        self: *const Node,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return switch (self.tag) {
            .root => @fieldParentPtr(Node.Root, "base", self).format(fmt, options, writer),
            .doc => @fieldParentPtr(Node.Doc, "base", self).format(fmt, options, writer),
            .map => @fieldParentPtr(Node.Map, "base", self).format(fmt, options, writer),
            .value => @fieldParentPtr(Node.Value, "base", self).format(fmt, options, writer),
        };
    }

    pub const Root = struct {
        base: Node = Node{ .tag = Tag.root, .tree = undefined },
        docs: std.ArrayListUnmanaged(*Node) = .{},
        eof: ?TokenIndex = null,

        pub const base_tag: Node.Tag = .root;

        pub fn deinit(self: *Root, allocator: *Allocator) void {
            for (self.docs.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.docs.deinit(allocator);
        }

        pub fn format(
            self: *const Root,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try std.fmt.format(writer, "Root {{ .docs = [ ", .{});
            for (self.docs.items) |node| {
                try std.fmt.format(writer, "{} ,", .{node});
            }
            return std.fmt.format(writer, "] }}", .{});
        }
    };

    pub const Doc = struct {
        base: Node = Node{ .tag = Tag.doc, .tree = undefined },
        start: ?TokenIndex = null,
        directive: ?TokenIndex = null,
        values: std.ArrayListUnmanaged(*Node) = .{},
        end: ?TokenIndex = null,

        pub const base_tag: Node.Tag = .doc;

        pub fn deinit(self: *Doc, allocator: *Allocator) void {
            for (self.values.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.values.deinit(allocator);
        }

        pub fn format(
            self: *const Doc,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try std.fmt.format(writer, "Doc {{ ", .{});
            if (self.directive) |id| {
                const directive = self.base.tree.tokens[id];
                try std.fmt.format(writer, ".directive = {s}, ", .{
                    self.base.tree.source[directive.start..directive.end],
                });
            }
            try std.fmt.format(writer, ".values = [ ", .{});
            for (self.values.items) |node| {
                try std.fmt.format(writer, "{} ,", .{node});
            }
            return std.fmt.format(writer, "] }}", .{});
        }
    };

    pub const Map = struct {
        base: Node = Node{ .tag = Tag.map, .tree = undefined },
        key: ?TokenIndex = null,
        value: ?*Node = null,

        pub const base_tag: Node.Tag = .map;

        pub fn deinit(self: *Map, allocator: *Allocator) void {
            if (self.value) |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            }
        }

        pub fn format(
            self: *const Map,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const key = self.base.tree.tokens[self.key.?];
            return std.fmt.format(writer, "Map {{ .key = {s}, .value = {} }}", .{
                self.base.tree.source[key.start..key.end],
                self.value.?,
            });
        }
    };

    pub const Value = struct {
        base: Node = Node{ .tag = Tag.value, .tree = undefined },
        value: ?TokenIndex = null,

        pub const base_tag: Node.Tag = .value;

        pub fn deinit(self: *Value, allocator: *Allocator) void {}

        pub fn format(
            self: *const Value,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const token = self.base.tree.tokens[self.value.?];
            return std.fmt.format(writer, "Value {{ .value = {s} }}", .{
                self.base.tree.source[token.start..token.end],
            });
        }
    };
};

pub const Tree = struct {
    allocator: *Allocator,
    source: []const u8,
    tokens: []Token,
    root: *Node.Root,

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.tokens);
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }
};

pub fn parse(allocator: *Allocator, source: []const u8) !Tree {
    var tokenizer = Tokenizer{
        .buffer = source,
    };
    var tokens = std.ArrayList(Token).init(allocator);

    while (true) {
        const token = tokenizer.next();
        try tokens.append(token);
        if (token.id == .Eof) break;
    }

    var tree = Tree{
        .allocator = allocator,
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .root = undefined,
    };
    var it = TokenIterator{
        .buffer = tree.tokens,
    };
    var parser = Parser{
        .allocator = allocator,
        .tree = &tree,
        .token_it = &it,
    };
    defer parser.deinit();
    tree.root = try parser.root();

    return tree;
}

const Parser = struct {
    allocator: *Allocator,
    tree: *Tree,
    token_it: *TokenIterator,

    const ParseError = error{
        NestedDocuments,
        UnexpectedTag,
        UnexpectedEof,
        UnexpectedToken,
        Unhandled,
    } || Allocator.Error;

    fn deinit(self: *Parser) void {}

    fn root(self: *Parser) ParseError!*Node.Root {
        const node = try self.allocator.create(Node.Root);
        errdefer self.allocator.destroy(node);
        node.* = .{};
        node.base.tree = self.tree;

        while (true) {
            if (self.token_it.peek()) |token| {
                if (token.id == .Eof) {
                    _ = self.token_it.next();
                    node.eof = self.token_it.getPos();
                    break;
                }
            }

            const curr_pos = self.token_it.getPos();
            const doc_node = try self.doc();
            doc_node.start = curr_pos;
            try node.docs.append(self.allocator, &doc_node.base);
        }

        return node;
    }

    fn doc(self: *Parser) ParseError!*Node.Doc {
        const node = try self.allocator.create(Node.Doc);
        errdefer self.allocator.destroy(node);
        node.* = .{};
        node.base.tree = self.tree;

        if (self.eatToken(.DocStart)) |_| {
            if (self.eatToken(.Tag)) |_| {
                node.directive = try self.expectToken(.Literal);
            }
        }

        _ = try self.expectToken(.NewLine);

        while (true) {
            const token = self.token_it.next();
            switch (token.id) {
                .DocStart => {
                    // TODO this should be an error token
                    return error.NestedDocuments;
                },
                .Tag => {
                    return error.UnexpectedTag;
                },
                .Literal => {
                    const curr_pos = self.token_it.getPos();
                    _ = try self.expectToken(.MapValueInd);
                    const map_node = try self.map();
                    map_node.key = curr_pos;
                    try node.values.append(self.allocator, &map_node.base);
                },
                .DocEnd => {
                    node.end = self.token_it.getPos();
                    break;
                },
                .Eof => {
                    return error.UnexpectedEof;
                },
                else => {},
            }
        }

        return node;
    }

    fn map(self: *Parser) ParseError!*Node.Map {
        const node = try self.allocator.create(Node.Map);
        errdefer self.allocator.destroy(node);
        node.* = .{};
        node.base.tree = self.tree;

        const indent: ?usize = if (self.eatToken(.NewLine)) |_| indent: {
            const token = self.token_it.next();
            if (token.id != .Space and token.id != .Tab) {
                // TODO bubble up error
                return error.UnexpectedToken;
            }
            break :indent token.count.?;
        } else null;

        while (true) {
            const token = self.token_it.next();
            switch (token.id) {
                .Literal => {
                    if (indent) |_| {
                        // nested map
                        const curr_pos = self.token_it.getPos();
                        _ = try self.expectToken(.MapValueInd);
                        const map_node = try self.map();
                        map_node.key = curr_pos;
                        node.value = &map_node.base;
                        break;
                    }

                    // standalone (leaf) value
                    const value = try self.allocator.create(Node.Value);
                    errdefer self.allocator.destroy(value);
                    value.* = .{
                        .value = self.token_it.getPos(),
                    };
                    value.base.tree = self.tree;
                    node.value = &value.base;
                    break;
                },
                else => return error.Unhandled,
            }
        }

        if (indent) |_| {
            _ = try self.expectToken(.NewLine);
        }

        return node;
    }

    fn eatCommentsAndSpace(self: *Parser) void {
        while (true) {
            const cur_pos = self.token_it.getPos();
            _ = self.token_it.peek() orelse return;
            const token = self.token_it.next();
            switch (token.id) {
                .Comment, .Space => {},
                else => {
                    self.token_it.resetTo(cur_pos);
                    break;
                },
            }
        }
    }

    fn eatToken(self: *Parser, id: Token.Id) ?TokenIndex {
        while (true) {
            const cur_pos = self.token_it.getPos();
            _ = self.token_it.peek() orelse return null;
            const token = self.token_it.next();
            switch (token.id) {
                .Comment, .Space => continue,
                else => |next_id| if (next_id == id) {
                    return self.token_it.getPos();
                } else {
                    self.token_it.resetTo(cur_pos);
                    return null;
                },
            }
        }
    }

    fn expectToken(self: *Parser, id: Token.Id) ParseError!TokenIndex {
        return self.eatToken(id) orelse error.UnexpectedToken;
    }
};

test "simple doc with single map and directive" {
    const source =
        \\--- !tapi-tbd
        \\tbd-version: 4
        \\...
    ;

    var tree = try parse(testing.allocator, source);
    defer tree.deinit();

    try testing.expectEqual(tree.root.docs.items.len, 1);

    const doc = tree.root.docs.items[0].cast(Node.Doc).?;
    try testing.expectEqual(doc.start.?, 0);
    try testing.expectEqual(doc.end.?, tree.tokens.len - 2);

    const directive = tree.tokens[doc.directive.?];
    try testing.expectEqual(directive.id, .Literal);
    try testing.expect(mem.eql(u8, "tapi-tbd", tree.source[directive.start..directive.end]));

    try testing.expectEqual(doc.values.items.len, 1);

    const map = doc.values.items[0].cast(Node.Map).?;
    const key = tree.tokens[map.key.?];
    try testing.expectEqual(key.id, .Literal);
    try testing.expect(mem.eql(u8, "tbd-version", tree.source[key.start..key.end]));

    const value = map.value.?.cast(Node.Value).?;
    const value_tok = tree.tokens[value.value.?];
    try testing.expectEqual(value_tok.id, .Literal);
    try testing.expect(mem.eql(u8, "4", tree.source[value_tok.start..value_tok.end]));
}

test "nested maps" {
    const source =
        \\---
        \\key1:
        \\  key1_1:value1_1
        \\key2:
        \\  key2_1:value2_1
        \\...
    ;

    var tree = try parse(testing.allocator, source);
    defer tree.deinit();

    try testing.expectEqual(tree.root.docs.items.len, 1);

    const doc = tree.root.docs.items[0].cast(Node.Doc).?;
    try testing.expectEqual(doc.start.?, 0);
    try testing.expectEqual(doc.end.?, tree.tokens.len - 2);
    try testing.expect(doc.directive == null);
    try testing.expectEqual(doc.values.items.len, 2);

    {
        // first value: map: key1 => { key1_1 => value1 }
        const map = doc.values.items[0].cast(Node.Map).?;
        const key1 = tree.tokens[map.key.?];
        try testing.expectEqual(key1.id, .Literal);
        try testing.expect(mem.eql(u8, "key1", tree.source[key1.start..key1.end]));

        const value1 = map.value.?.cast(Node.Map).?;
        const key1_1 = tree.tokens[value1.key.?];
        try testing.expectEqual(key1_1.id, .Literal);
        try testing.expect(mem.eql(u8, "key1_1", tree.source[key1_1.start..key1_1.end]));

        const value1_1 = value1.value.?.cast(Node.Value).?;
        const value1_1_tok = tree.tokens[value1_1.value.?];
        try testing.expectEqual(value1_1_tok.id, .Literal);
        try testing.expect(mem.eql(
            u8,
            "value1_1",
            tree.source[value1_1_tok.start..value1_1_tok.end],
        ));
    }

    {
        // second value: map: key2 => { key2_1 => value2 }
        const map = doc.values.items[1].cast(Node.Map).?;
        const key2 = tree.tokens[map.key.?];
        try testing.expectEqual(key2.id, .Literal);
        try testing.expect(mem.eql(u8, "key2", tree.source[key2.start..key2.end]));

        const value2 = map.value.?.cast(Node.Map).?;
        const key2_1 = tree.tokens[value2.key.?];
        try testing.expectEqual(key2_1.id, .Literal);
        try testing.expect(mem.eql(u8, "key2_1", tree.source[key2_1.start..key2_1.end]));

        const value2_1 = value2.value.?.cast(Node.Value).?;
        const value2_1_tok = tree.tokens[value2_1.value.?];
        try testing.expectEqual(value2_1_tok.id, .Literal);
        try testing.expect(mem.eql(
            u8,
            "value2_1",
            tree.source[value2_1_tok.start..value2_1_tok.end],
        ));
    }
}
