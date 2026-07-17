space: Io.Threaded.WindowsPathSpace,

const Wtf16ToPrefixedFileWOptions = @typeInfo(
    @TypeOf(Io.Threaded.sliceToPrefixedFileW),
).@"fn".params[2].type.?;

const Wtf8ToPrefixedFileWError = @typeInfo(@typeInfo(
    @TypeOf(Io.Threaded.sliceToPrefixedFileW),
).@"fn".return_type.?).error_union.error_set;

const Wtf16ToPrefixedFileWError = @typeInfo(@typeInfo(
    @TypeOf(Io.Threaded.wToPrefixedFileW),
).@"fn".return_type.?).error_union.error_set;

const LocalDevicePathType = enum {
    /// `\\.\` (path separators can be `\` or `/`)
    local_device,
    /// `\\?\`
    /// When converted to an NT path, everything past the prefix is left
    /// untouched and `\\?\` is replaced by `\??\`.
    verbatim,
    /// `\\?\` without all path separators being `\`.
    /// This seems to be recognized as a prefix, but the 'verbatim' aspect
    /// is not respected (i.e. if `//?/C:/foo` is converted to an NT path,
    /// it will become `\??\C:\foo` [it will be canonicalized and the //?/ won't
    /// be treated as part of the final path])
    fake_verbatim,
};

pub fn initPinned(buffer: *PathBuffer, dir: Io.Dir.Handle, path: []const u8) !void {
    var dir_path_buf: [windows.PATH_MAX_WIDE:0]u16 = undefined; // temporary
    try sliceToPrefixedFileW(dir, path, &dir_path_buf, &buffer.space);
}

fn getLocalDevicePathType(comptime T: type, path: []const T) LocalDevicePathType {
    const backslash = std.mem.nativeToLittle(T, '\\');
    const all_backslash = path[0] == backslash and
        path[1] == backslash and
        path[3] == backslash;
    return switch (path[2]) {
        std.mem.nativeToLittle(T, '?') => if (all_backslash) .verbatim else .fake_verbatim,
        std.mem.nativeToLittle(T, '.') => .local_device,
        else => unreachable,
    };
}

fn sliceToPrefixedFileW(
    dir: ?windows.HANDLE,
    path: []const u8,
    dir_path_buf: *[windows.PATH_MAX_WIDE:0]u16,
    out: *Io.Threaded.WindowsPathSpace,
) Wtf8ToPrefixedFileWError!void {
    var temp_path: Io.Threaded.WindowsPathSpace = undefined;
    temp_path.len = std.unicode.wtf8ToWtf16Le(&temp_path.data, path) catch |err| switch (err) {
        error.InvalidWtf8 => return error.BadPathName,
    };
    temp_path.data[temp_path.len] = 0;
    return wToPrefixedFileW(dir, temp_path.span(), dir_path_buf, out);
}

pub fn wToPrefixedFileW(
    dir: ?windows.HANDLE,
    path: [:0]const u16,
    dir_path_buf: *[windows.PATH_MAX_WIDE:0]u16,
    path_space: *Io.Threaded.WindowsPathSpace,
) Wtf16ToPrefixedFileWError!void {
    const nt_prefix = [_]u16{ '\\', '?', '?', '\\' };
    if (windows.hasCommonNtPrefix(u16, path)) {
        path_space.data[0..nt_prefix.len].* = nt_prefix;
        const len_after_prefix = path.len - nt_prefix.len;
        @memcpy(path_space.data[nt_prefix.len..][0..len_after_prefix], path[nt_prefix.len..]);
        path_space.len = path.len;
        path_space.data[path_space.len] = 0;
        return;
    } else {
        const path_type = Io.Dir.path.getWin32PathType(u16, path);
        if (path_type == .local_device) switch (getLocalDevicePathType(u16, path)) {
            .verbatim => {
                path_space.data[0..nt_prefix.len].* = nt_prefix;
                const len_after_prefix = path.len - nt_prefix.len;
                @memcpy(path_space.data[nt_prefix.len..][0..len_after_prefix], path[nt_prefix.len..]);
                path_space.len = path.len;
                path_space.data[path_space.len] = 0;
                return;
            },
            .local_device, .fake_verbatim => {
                const path_byte_len = windows.ntdll.RtlGetFullPathName_U(
                    path.ptr,
                    path_space.data.len * 2,
                    &path_space.data,
                    null,
                );
                if (path_byte_len == 0) {
                    // TODO: This may not be the right error
                    return error.BadPathName;
                } else if (path_byte_len / 2 > path_space.data.len) {
                    return error.NameTooLong;
                }
                path_space.len = path_byte_len / 2;
                // Both prefixes will be normalized but retained, so all
                // we need to do now is replace them with the NT prefix
                path_space.data[0..nt_prefix.len].* = nt_prefix;
                return;
            },
        };
        if (path_type == .relative) relative: {
            // TODO: Handle special case device names like COM1, AUX, NUL, CONIN$, CONOUT$, etc.
            //       See https://googleprojectzero.blogspot.com/2016/02/the-definitive-guide-on-win32-to-nt.html

            // TODO: Potentially strip all trailing . and space characters from the
            //       end of the path. This is something that both RtlDosPathNameToNtPathName_U
            //       and RtlGetFullPathName_U do. Technically, trailing . and spaces
            //       are allowed, but such paths may not interact well with Windows (i.e.
            //       files with these paths can't be deleted from explorer.exe, etc).
            //       This could be something that normalizePath may want to do.

            @memcpy(path_space.data[0..path.len], path);
            // Try to normalize, but if we get too many parent directories,
            // then we need to start over and use RtlGetFullPathName_U instead.
            path_space.len = windows.normalizePath(u16, path_space.data[0..path.len]) catch |err| switch (err) {
                error.TooManyParentDirs => break :relative,
            };
            path_space.data[path_space.len] = 0;
            return;
        }
        // We now know we are going to return an absolute NT path, so
        // we can unconditionally prefix it with the NT prefix.
        path_space.data[0..nt_prefix.len].* = nt_prefix;
        if (path_type == .root_local_device) {
            // `\\.` and `\\?` always get converted to `\??\` exactly, so
            // we can just stop here
            path_space.len = nt_prefix.len;
            path_space.data[path_space.len] = 0;
            return;
        }
        const path_buf_offset = switch (path_type) {
            // UNC paths will always start with `\\`. However, we want to
            // end up with something like `\??\UNC\server\share`, so to get
            // RtlGetFullPathName to write into the spot we want the `server`
            // part to end up, we need to provide an offset such that
            // the `\\` part gets written where the `C\` of `UNC\` will be
            // in the final NT path.
            .unc_absolute => nt_prefix.len + 2,
            else => nt_prefix.len,
        };
        const buf_len: u32 = @intCast(path_space.data.len - path_buf_offset);
        const path_to_get: [:0]const u16 = path_to_get: {
            // If dir is null, then we don't need to bother with GetFinalPathNameByHandle because
            // RtlGetFullPathName_U will resolve relative paths against the CWD for us.
            if (path_type != .relative or dir == null) {
                break :path_to_get path;
            }
            // We can also skip GetFinalPathNameByHandle if the handle matches
            // the handle returned by Io.Dir.cwd()
            if (dir.? == Io.Dir.cwd().handle) {
                break :path_to_get path;
            }
            // At this point, we know we have a relative path that had too many
            // `..` components to be resolved by normalizePath, so we need to
            // convert it into an absolute path and let RtlGetFullPathName_U
            // canonicalize it. We do this by getting the path of the `dir`
            // and appending the relative path to it.
            const dir_path = Io.Threaded.GetFinalPathNameByHandle(dir.?, .{}, dir_path_buf) catch |err| switch (err) {
                // This mapping is not correct; it is actually expected
                // that calling GetFinalPathNameByHandle might return
                // error.UnrecognizedVolume, and in fact has been observed
                // in the wild. The problem is that wToPrefixedFileW was
                // never intended to make *any* OS syscall APIs. It's only
                // supposed to convert a string to one that is eligible to
                // be used in the ntdll syscalls.
                //
                // To solve this, this function needs to no longer call
                // GetFinalPathNameByHandle under any conditions, or the
                // calling function needs to get reworked to not need to
                // call this function.
                //
                // This may involve making breaking API changes.
                error.UnrecognizedVolume => return error.Unexpected,
                else => |e| return e,
            };
            if (dir_path.len + 1 + path.len > windows.PATH_MAX_WIDE) {
                return error.NameTooLong;
            }
            // We don't have to worry about potentially doubling up path separators
            // here since RtlGetFullPathName_U will handle canonicalizing it.
            dir_path_buf[dir_path.len] = '\\';
            @memcpy(dir_path_buf[dir_path.len + 1 ..][0..path.len], path);
            const full_len = dir_path.len + 1 + path.len;
            dir_path_buf[full_len] = 0;
            break :path_to_get dir_path_buf[0..full_len :0];
        };
        const path_byte_len = windows.ntdll.RtlGetFullPathName_U(
            path_to_get.ptr,
            buf_len * 2,
            path_space.data[path_buf_offset..].ptr,
            null,
        );
        if (path_byte_len == 0) {
            // TODO: This may not be the right error
            return error.BadPathName;
        } else if (path_byte_len / 2 > buf_len) {
            return error.NameTooLong;
        }
        path_space.len = path_buf_offset + (path_byte_len / 2);
        if (path_type == .unc_absolute) {
            // Now add in the UNC, the `C` should overwrite the first `\` of the
            // FullPathName, ultimately resulting in `\??\UNC\<the rest of the path>`
            const unc = [_]u16{ 'U', 'N', 'C' };
            path_space.data[nt_prefix.len..][0..unc.len].* = unc;
        }
        return;
    }
}

const Io = std.Io;
const windows = std.os.windows;
const std = @import("std");
const PathBuffer = @This();
