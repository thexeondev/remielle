const std = @import("std");
const Io = std.Io;

pub fn print(io: Io) void {
    Io.File.stderr().writeStreamingAll(io,
        \\    ____                 _      ____   
        \\   / __ \___  ____ ___  (_)__  / / /__ 
        \\  / /_/ / _ \/ __ `__ \/ / _ \/ / / _ \
        \\ / _, _/  __/ / / / / / /  __/ / /  __/
        \\/_/ |_|\___/_/ /_/ /_/_/\___/_/_/\___/ 
        \\
    ) catch {};
}
