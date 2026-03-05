/// Intrusive FIFO queue using a singly-linked list.
/// Items must have a `next` field of type `?*T`.
pub fn IntrusiveQueue(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();

        pub fn push(self: *Self, item: *T) void {
            item.next = null;
            if (self.tail) |tail| {
                tail.next = item;
            } else {
                self.head = item;
            }
            self.tail = item;
        }

        pub fn pop(self: *Self) ?*T {
            const head = self.head orelse return null;
            self.head = head.next;
            if (self.head == null) self.tail = null;
            head.next = null;
            return head;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }
    };
}
