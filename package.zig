const std = @import("std");
const sg = @import("sokol").gfx;
const sapp = @import("sokol").app;
const zgui = @import("zig_gamedev_zgui");
const shaders = @import("sokol_zgui_embedded_shaders.zig");

const DrawVert = zgui.DrawVert;
const DrawIdx = zgui.DrawIdx;

pub const Config = struct {
    allocator: std.mem.Allocator,

    max_vertices: usize = 65536,

    colour_format: sg.PixelFormat = .DEFAULT,
    depth_format: sg.PixelFormat = .DEFAULT,
};

pub const NewFrame = struct {
    width: f32,
    height: f32,
    delta_time: f32,
    dpi_scale: f32 = 1,
};

const ZguiSokol = struct {
    const Self = @This();

    allocator: std.mem.Allocator = undefined,

    current_frame: NewFrame = undefined,
    colour_format: sg.PixelFormat = .DEFAULT,
    depth_format: sg.PixelFormat = .DEFAULT,

    vertices: []DrawVert = undefined,
    indices: []DrawIdx = undefined,
    sg_vertex_buffer: sg.Buffer = undefined,
    sg_index_buffer: sg.Buffer = undefined,
    sg_font_image: sg.Image = undefined,
    sg_shader: sg.Shader = undefined,
    sg_pipeline: sg.Pipeline = undefined,
};

const VsParams = struct {
    disp_size: [2]f32,
    _pad_: u64 = undefined,
};

var backend = ZguiSokol{};

fn isOsx() bool {
    switch (backend.queryBackend()) {
        .METAL_IOS, .METAL_MACOS, .METAL_SIMULATOR => return true,
        else => return false,
    }
}

pub fn init(config: Config) !void {
    backend.allocator = config.allocator;

    sg.pushDebugGroup("sokol-imgui");

    // vertex buffer creations
    backend.vertices = try std.mem.Allocator.alloc(backend.allocator, DrawVert, config.max_vertices);
    backend.sg_vertex_buffer = sg.makeBuffer(.{
        .size = backend.vertices.len * @sizeOf(DrawVert),
        .type = .VERTEXBUFFER,
        .usage = .STREAM,
        .label = "sokol-imgui-vertices",
    });

    // index buffer creaion
    backend.indices = try std.mem.Allocator.alloc(backend.allocator, DrawIdx, config.max_vertices * 3);
    backend.sg_index_buffer = sg.makeBuffer(.{
        .size = backend.indices.len * @sizeOf(DrawIdx),
        .type = .INDEXBUFFER,
        .usage = .STREAM,
        .label = "sokol-imgui-indices",
    });

    // font upload to sokol
    var font_width: i32 = undefined;
    var font_height: i32 = undefined;
    const font_pixels = zgui.io.getFontsTextDataAsRgba32(&font_width, &font_height);
    var font_img_desc: sg.ImageDesc = .{
        .width = font_width,
        .height = font_height,
        .pixel_format = .RGBA8,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .label = "sokol-imgui-font",
    };
    // FIXME: https://github.com/ziglang/zig/issues/6068
    font_img_desc.data.subimage[0][0].ptr = font_pixels;
    font_img_desc.data.subimage[0][0].size = @intCast(usize, font_width * font_height * 4);
    backend.sg_font_image = sg.makeImage(font_img_desc);
    zgui.io.setFontsTexId(@intToPtr(*anyopaque, backend.sg_font_image.id));

    // upload shader byte code
    var shader_description: sg.ShaderDesc = .{
        .label = "sokol-imgui-shader",
    };
    shader_description.attrs[0] = .{
        .name = "position",
        .sem_name = "TEXCOORD",
        .sem_index = 0,
    };
    shader_description.attrs[1] = .{
        .name = "texcoord0",
        .sem_name = "TEXCOORD",
        .sem_index = 1,
    };
    shader_description.attrs[2] = .{
        .name = "color0",
        .sem_name = "TEXCOORD",
        .sem_index = 2,
    };

    shader_description.vs = switch (sg.queryBackend()) {
        .GLCORE33 => .{ .source = &shaders.zgui_vs_source_glsl330 },
        .GLES2 => .{ .source = &shaders.zgui_vs_source_glsl100 },
        .D3D11 => .{ .bytecode = sg.asRange(&shaders.zgui_vs_bytecode_hlsl4) },
        .METAL_IOS => .{ .bytecode = sg.asRange(&shaders.zgui_vs_bytecode_metal_ios) },
        .METAL_MACOS => .{ .bytecode = sg.asRange(&shaders.zgui_vs_bytecode_metal_macos) },
        .METAL_SIMULATOR => .{ .source = &shaders.zgui_vs_source_metal_sim },
        .WGPU => .{ .bytecode = sg.asRange(&shaders.zgui_vs_bytecode_wgpu) },
        else => .{ .source = &shaders.zgui_vs_source_dummy },
    };
    shader_description.vs.uniform_blocks[0].uniforms[0] = .{
        .name = "vs_params",
        .type = .FLOAT4,
        .array_count = 1,
    };
    shader_description.vs.uniform_blocks[0].size = @sizeOf(VsParams);

    shader_description.fs = switch (sg.queryBackend()) {
        .GLCORE33 => .{ .source = &shaders.zgui_fs_source_glsl330 },
        .GLES2 => .{ .source = &shaders.zgui_fs_source_glsl100 },
        .D3D11 => .{ .bytecode = sg.asRange(&shaders.zgui_fs_bytecode_hlsl4) },
        .METAL_IOS => .{ .bytecode = sg.asRange(&shaders.zgui_fs_bytecode_metal_ios) },
        .METAL_MACOS => .{ .bytecode = sg.asRange(&shaders.zgui_fs_bytecode_metal_macos) },
        .METAL_SIMULATOR => .{ .source = &shaders.zgui_fs_source_metal_sim },
        .WGPU => .{ .bytecode = sg.asRange(&shaders.zgui_fs_bytecode_wgpu) },
        else => .{ .source = &shaders.zgui_fs_source_dummy },
    };
    shader_description.fs.images[0] = .{
        .name = "tex",
        .image_type = ._2D,
        .sampler_type = .FLOAT,
    };
    backend.sg_shader = sg.makeShader(shader_description);

    var pipeline_description: sg.PipelineDesc = .{
        .shader = backend.sg_shader,
        .index_type = .UINT16,
        .depth = .{ .pixel_format = config.depth_format },
        .label = "sokol-imgui-pipeline",
    };
    pipeline_description.layout.buffers[0].stride = @sizeOf(DrawVert);
    pipeline_description.layout.attrs[0] = .{ .offset = @offsetOf(DrawVert, "pos"), .format = .FLOAT2 };
    pipeline_description.layout.attrs[1] = .{ .offset = @offsetOf(DrawVert, "uv"), .format = .FLOAT2 };
    pipeline_description.layout.attrs[2] = .{ .offset = @offsetOf(DrawVert, "color"), .format = .UBYTE4N };
    pipeline_description.colors[0] = .{
        .pixel_format = config.colour_format,
        .write_mask = .RGB,
        .blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        },
    };
    backend.sg_pipeline = sg.makePipeline(pipeline_description);

    sg.popDebugGroup();
}

pub fn deinit() void {
    sg.pushDebugGroup("sokol-imgui");
    sg.destroyPipeline(backend.sg_pipeline);
    sg.destroyShader(backend.sg_shader);
    sg.destroyBuffer(backend.sg_index_buffer);
    sg.destroyBuffer(backend.sg_vertex_buffer);
    sg.popDebugGroup();

    backend.allocator.free(backend.indices);
    backend.allocator.free(backend.vertices);
}

pub fn newFrame(frame: NewFrame) void {
    backend.current_frame = frame;

    zgui.io.setDisplaySize(frame.width / frame.dpi_scale, frame.height / frame.dpi_scale);
    zgui.io.setDeltaTime(frame.delta_time);

    // if (zgui.io.getWantTextInput() and !sapp.keyboardShown()) {
    //     sapp.showKeyboard(true);
    // }
    // if (!zgui.io.getWantTextInput() and sapp.keyboardShown()) {
    //     sapp.showKeyboard(false);
    // }
    const cursor = switch (zgui.getMouseCursor()) {
        .arrow => sapp.MouseCursor.ARROW,
        .text_input => sapp.MouseCursor.IBEAM,
        .resize_all => sapp.MouseCursor.RESIZE_ALL,
        .resize_ns => sapp.MouseCursor.RESIZE_NS,
        .resize_ew => sapp.MouseCursor.RESIZE_EW,
        .resize_nesw => sapp.MouseCursor.RESIZE_NESW,
        .resize_nwse => sapp.MouseCursor.RESIZE_NESW,
        .hand => sapp.MouseCursor.POINTING_HAND,
        .not_allowed => sapp.MouseCursor.NOT_ALLOWED,
        else => sapp.MouseCursor.NOT_ALLOWED,
    };
    if (sapp.getMouseCursor() != cursor) {
        sapp.setMouseCursor(cursor);
    }

    zgui.newFrame();
}

pub fn render() void {
    zgui.render();

    const draw_data = zgui.getDrawData();
    if (!draw_data.valid) return;

    var all_vtx_count: usize = 0;
    var all_idx_count: usize = 0;

    {
        std.debug.assert(draw_data.cmd_lists_count >= 0);
        var cmd_list_count: usize = 0;
        while (cmd_list_count < draw_data.cmd_lists_count) : (cmd_list_count += 1) {
            const cmd_list = draw_data.cmd_lists[cmd_list_count];
            const vtx_count = @intCast(usize, cmd_list.getVertexBufferLength());
            const idx_count = @intCast(usize, cmd_list.getIndexBufferLength());
            if ((all_vtx_count + vtx_count > backend.vertices.len) or
                (all_idx_count + idx_count > backend.indices.len)) continue;

            for (cmd_list.getVertexBufferData()[0..vtx_count]) |v, i| backend.vertices[i + all_vtx_count] = v;
            for (cmd_list.getIndexBufferData()[0..idx_count]) |v, i| backend.indices[i + all_idx_count] = v;

            all_vtx_count += vtx_count;
            all_idx_count += idx_count;
        }
        if (cmd_list_count == 0) return;
    }

    sg.pushDebugGroup("sokol-imgui");
    if (all_vtx_count > 0) sg.updateBuffer(backend.sg_vertex_buffer, sg.asRange(backend.vertices));
    if (all_idx_count > 0) sg.updateBuffer(backend.sg_index_buffer, sg.asRange(backend.indices));

    const fb_width = @floatToInt(i32, backend.current_frame.width * backend.current_frame.dpi_scale);
    const fb_height = @floatToInt(i32, backend.current_frame.height * backend.current_frame.dpi_scale);
    sg.applyViewport(0, 0, fb_width, fb_height, true);
    sg.applyScissorRect(0, 0, fb_width, fb_height, true);

    sg.applyPipeline(backend.sg_pipeline);
    const vs_params: VsParams = .{ .disp_size = .{ backend.current_frame.width, backend.current_frame.height } };
    sg.applyUniforms(.VS, 0, sg.asRange(&vs_params));

    var bind: sg.Bindings = .{
        .index_buffer = backend.sg_index_buffer,
    };
    bind.vertex_buffers[0] = backend.sg_vertex_buffer;
    var tex_id: *anyopaque = zgui.io.getFontsTexId();
    bind.fs_images[0].id = @intCast(u32, @ptrToInt(tex_id));

    {
        var vb_offset: i32 = 0;
        var ib_offset: i32 = 0;
        std.debug.assert(draw_data.cmd_lists_count >= 0);
        var cmd_list_count: usize = 0;
        while (cmd_list_count < draw_data.cmd_lists_count) : (cmd_list_count += 1) {
            const cmd_list = draw_data.cmd_lists[cmd_list_count];

            // -1 to start will force the initial applyBindings
            var vtx_offset: i32 = -1;
            {
                var cmd_index: usize = 0;
                while (cmd_index < cmd_list.getCmdBufferLength()) : (cmd_index += 1) {
                    const cmd = cmd_list.getCmdBufferData()[cmd_index];
                    if (cmd.user_callback == null) {
                        if (tex_id != cmd.texture_id or vtx_offset != cmd.vtx_offset) {
                            tex_id = cmd.texture_id;
                            vtx_offset = @intCast(i32, cmd.vtx_offset);
                            bind.fs_images[0].id = @intCast(u32, @ptrToInt(tex_id));
                            bind.vertex_buffer_offsets[0] = vb_offset + (vtx_offset * @sizeOf(DrawVert));
                            bind.index_buffer_offset = ib_offset;
                            sg.applyBindings(bind);
                        }
                        const scissor_x = @floatToInt(i32, cmd.clip_rect[0] * backend.current_frame.dpi_scale);
                        const scissor_y = @floatToInt(i32, cmd.clip_rect[1] * backend.current_frame.dpi_scale);
                        const scissor_w = @floatToInt(i32, (cmd.clip_rect[2] - cmd.clip_rect[0]) * backend.current_frame.dpi_scale);
                        const scissor_h = @floatToInt(i32, (cmd.clip_rect[3] - cmd.clip_rect[1]) * backend.current_frame.dpi_scale);
                        sg.applyScissorRect(scissor_x, scissor_y, scissor_w, scissor_h, true);
                        sg.draw(cmd.idx_offset, cmd.elem_count, 1);
                    } else {
                        // todo user callbacks
                    }
                }
                vb_offset += cmd_list.getVertexBufferLength() * @sizeOf(DrawVert);
                ib_offset += cmd_list.getIndexBufferLength() * @sizeOf(DrawIdx);
            }
        }
    }
    sg.applyViewport(0, 0, fb_width, fb_height, true);
    sg.applyScissorRect(0, 0, fb_width, fb_height, true);
    sg.popDebugGroup();
}

fn isCtrl(modifiers: zgui.KeyModifiers) bool {
    if (isOsx) {
        return modifiers.super;
    } else return modifiers.ctrl;
}

fn mapKeycode(key: sapp.Keycode) zgui.Key {
    switch (key) {
        sapp.Keycode.SPACE => return zgui.Key.space,
        sapp.Keycode.APOSTROPHE => return zgui.Key.apostrophe,
        sapp.Keycode.COMMA => return zgui.Key.comma,
        sapp.Keycode.MINUS => return zgui.Key.minus,
        sapp.Keycode.PERIOD => return zgui.Key.apostrophe,
        sapp.Keycode.SLASH => return zgui.Key.slash,
        sapp.Keycode._0 => return zgui.Key._0,
        sapp.Keycode._1 => return zgui.Key._1,
        sapp.Keycode._2 => return zgui.Key._2,
        sapp.Keycode._3 => return zgui.Key._3,
        sapp.Keycode._4 => return zgui.Key._4,
        sapp.Keycode._5 => return zgui.Key._5,
        sapp.Keycode._6 => return zgui.Key._6,
        sapp.Keycode._7 => return zgui.Key._7,
        sapp.Keycode._8 => return zgui.Key._8,
        sapp.Keycode._9 => return zgui.Key._9,
        sapp.Keycode.SEMICOLON => return zgui.Key.semicolon,
        sapp.Keycode.EQUAL => return zgui.Key.equal,
        sapp.Keycode.A => return zgui.Key.a,
        sapp.Keycode.B => return zgui.Key.b,
        sapp.Keycode.C => return zgui.Key.c,
        sapp.Keycode.D => return zgui.Key.d,
        sapp.Keycode.E => return zgui.Key.e,
        sapp.Keycode.F => return zgui.Key.f,
        sapp.Keycode.G => return zgui.Key.g,
        sapp.Keycode.H => return zgui.Key.h,
        sapp.Keycode.I => return zgui.Key.i,
        sapp.Keycode.J => return zgui.Key.j,
        sapp.Keycode.K => return zgui.Key.k,
        sapp.Keycode.L => return zgui.Key.l,
        sapp.Keycode.M => return zgui.Key.m,
        sapp.Keycode.N => return zgui.Key.n,
        sapp.Keycode.O => return zgui.Key.o,
        sapp.Keycode.P => return zgui.Key.p,
        sapp.Keycode.Q => return zgui.Key.q,
        sapp.Keycode.R => return zgui.Key.r,
        sapp.Keycode.S => return zgui.Key.s,
        sapp.Keycode.T => return zgui.Key.t,
        sapp.Keycode.U => return zgui.Key.u,
        sapp.Keycode.V => return zgui.Key.v,
        sapp.Keycode.W => return zgui.Key.w,
        sapp.Keycode.X => return zgui.Key.x,
        sapp.Keycode.Y => return zgui.Key.y,
        sapp.Keycode.Z => return zgui.Key.z,
        sapp.Keycode.LEFT_BRACKET => return zgui.Key.left_bracket,
        sapp.Keycode.BACKSLASH => return zgui.Key.back_slash,
        sapp.Keycode.RIGHT_BRACKET => return zgui.Key.right_bracket,
        sapp.Keycode.GRAVE_ACCENT => return zgui.Key.grave_accent,
        sapp.Keycode.ESCAPE => return zgui.Key.escape,
        sapp.Keycode.ENTER => return zgui.Key.enter,
        sapp.Keycode.TAB => return zgui.Key.tab,
        sapp.Keycode.BACKSPACE => return zgui.Key.back_space,
        sapp.Keycode.INSERT => return zgui.Key.insert,
        sapp.Keycode.DELETE => return zgui.Key.delete,
        sapp.Keycode.RIGHT => return zgui.Key.right_arrow,
        sapp.Keycode.LEFT => return zgui.Key.left_arrow,
        sapp.Keycode.DOWN => return zgui.Key.down_arrow,
        sapp.Keycode.UP => return zgui.Key.up_arrow,
        sapp.Keycode.PAGE_UP => return zgui.Key.page_up,
        sapp.Keycode.PAGE_DOWN => return zgui.Key.page_down,
        sapp.Keycode.HOME => return zgui.Key.home,
        sapp.Keycode.END => return zgui.Key.end,
        sapp.Keycode.CAPS_LOCK => return zgui.Key.caps_lock,
        sapp.Keycode.SCROLL_LOCK => return zgui.Key.scroll_lock,
        sapp.Keycode.NUM_LOCK => return zgui.Key.num_lock,
        sapp.Keycode.PRINT_SCREEN => return zgui.Key.print_screen,
        sapp.Keycode.PAUSE => return zgui.Key.pause,
        sapp.Keycode.F1 => return zgui.Key.f1,
        sapp.Keycode.F2 => return zgui.Key.f2,
        sapp.Keycode.F3 => return zgui.Key.f3,
        sapp.Keycode.F4 => return zgui.Key.f4,
        sapp.Keycode.F5 => return zgui.Key.f5,
        sapp.Keycode.F6 => return zgui.Key.f6,
        sapp.Keycode.F7 => return zgui.Key.f7,
        sapp.Keycode.F8 => return zgui.Key.f8,
        sapp.Keycode.F9 => return zgui.Key.f9,
        sapp.Keycode.F10 => return zgui.Key.f10,
        sapp.Keycode.F11 => return zgui.Key.f11,
        sapp.Keycode.F12 => return zgui.Key.f12,
        sapp.Keycode.KP_0 => return zgui.Key.keypad_0,
        sapp.Keycode.KP_1 => return zgui.Key.keypad_1,
        sapp.Keycode.KP_2 => return zgui.Key.keypad_2,
        sapp.Keycode.KP_3 => return zgui.Key.keypad_3,
        sapp.Keycode.KP_4 => return zgui.Key.keypad_4,
        sapp.Keycode.KP_5 => return zgui.Key.keypad_5,
        sapp.Keycode.KP_6 => return zgui.Key.keypad_6,
        sapp.Keycode.KP_7 => return zgui.Key.keypad_7,
        sapp.Keycode.KP_8 => return zgui.Key.keypad_8,
        sapp.Keycode.KP_9 => return zgui.Key.keypad_9,
        sapp.Keycode.KP_DECIMAL => return zgui.Key.keypad_decimal,
        sapp.Keycode.KP_DIVIDE => return zgui.Key.keypad_divide,
        sapp.Keycode.KP_MULTIPLY => return zgui.Key.keypad_multiply,
        sapp.Keycode.KP_SUBTRACT => return zgui.Key.keypad_subtract,
        sapp.Keycode.KP_ADD => return zgui.Key.keypad_add,
        sapp.Keycode.KP_ENTER => return zgui.Key.keypad_enter,
        sapp.Keycode.KP_EQUAL => return zgui.Key.keypad_equal,
        sapp.Keycode.LEFT_SHIFT => return zgui.Key.left_shift,
        sapp.Keycode.LEFT_CONTROL => return zgui.Key.left_ctrl,
        sapp.Keycode.LEFT_ALT => return zgui.Key.left_alt,
        sapp.Keycode.LEFT_SUPER => return zgui.Key.left_super,
        sapp.Keycode.RIGHT_SHIFT => return zgui.Key.right_shift,
        sapp.Keycode.RIGHT_CONTROL => return zgui.Key.right_ctrl,
        sapp.Keycode.RIGHT_ALT => return zgui.Key.right_alt,
        sapp.Keycode.RIGHT_SUPER => return zgui.Key.right_super,
        sapp.Keycode.MENU => return zgui.Key.menu,
        else => return zgui.Key.none,
    }
}

fn mapMouseButton(mouse_button: sapp.Mousebutton) zgui.MouseButton {
    switch (mouse_button) {
        .LEFT => return zgui.MouseButton.left,
        .MIDDLE => return zgui.MouseButton.middle,
        .RIGHT => return zgui.MouseButton.right,
        else => return zgui.MouseButton.right,
    }
}

fn updateModifiers(mods: u32) void {
    zgui.io.addKeyEvent(zgui.Key.mod_ctrl, (mods & sapp.modifier_ctrl) != 0);
    zgui.io.addKeyEvent(zgui.Key.mod_shift, (mods & sapp.modifier_shift) != 0);
    zgui.io.addKeyEvent(zgui.Key.mod_alt, (mods & sapp.modifier_alt) != 0);
    zgui.io.addKeyEvent(zgui.Key.mod_super, (mods & sapp.modifier_super) != 0);
}

fn addKeyEvent(keycode: sapp.Keycode, down: bool) void {
    const guiKey = mapKeycode(keycode);
    zgui.io.addKeyEvent(guiKey, down);
    zgui.io.setKeyEventNativeData(guiKey, @enumToInt(keycode), 0);
}

pub fn eventHandler(event: *const sapp.Event) bool {
    switch (event.type) {
        .FOCUSED => {
            zgui.io.addFocusEvent(true);
        },
        .UNFOCUSED => {
            zgui.io.addFocusEvent(false);
        },
        .MOUSE_DOWN => {
            zgui.io.addMouseButtonEvent(mapMouseButton(event.mouse_button), true);
            zgui.io.addMousePositionEvent(event.mouse_x / backend.current_frame.dpi_scale, event.mouse_y / backend.current_frame.dpi_scale);
            updateModifiers(event.modifiers);
        },
        .MOUSE_UP => {
            zgui.io.addMouseButtonEvent(mapMouseButton(event.mouse_button), false);
            zgui.io.addMousePositionEvent(event.mouse_x / backend.current_frame.dpi_scale, event.mouse_y / backend.current_frame.dpi_scale);
            updateModifiers(event.modifiers);
        },
        .MOUSE_MOVE => {
            zgui.io.addMousePositionEvent(event.mouse_x / backend.current_frame.dpi_scale, event.mouse_y / backend.current_frame.dpi_scale);
        },
        .MOUSE_ENTER, .MOUSE_LEAVE => {},
        .MOUSE_SCROLL => {
            zgui.io.addMouseWheelEvent(event.scroll_x, event.scroll_y);
        },
        .TOUCHES_BEGAN => {
            zgui.io.addMouseButtonEvent(zgui.MouseButton.left, true);
            zgui.io.addMousePositionEvent(event.touches[0].pos_x / backend.current_frame.dpi_scale, event.touches[0].pos_y / backend.current_frame.dpi_scale);
        },
        .TOUCHES_MOVED => {
            zgui.io.addMousePositionEvent(event.touches[0].pos_x / backend.current_frame.dpi_scale, event.touches[0].pos_y / backend.current_frame.dpi_scale);
        },
        .TOUCHES_ENDED => {
            zgui.io.addMouseButtonEvent(zgui.MouseButton.left, false);
            zgui.io.addMousePositionEvent(event.touches[0].pos_x / backend.current_frame.dpi_scale, event.touches[0].pos_y / backend.current_frame.dpi_scale);
        },
        .TOUCHES_CANCELLED => {
            zgui.io.addMouseButtonEvent(zgui.MouseButton.left, false);
        },
        .KEY_DOWN => {
            updateModifiers(event.modifiers);
            // TODO cut and paste
            // intercept Ctrl-V, this is handled via EVENTTYPE_CLIPBOARD_PASTED
            // if (!_simgui.desc.disable_paste_override) {
            //     if (_simgui_is_ctrl(ev->modifiers) && (ev->key_code == SAPP_KEYCODE_V)) {
            //         break;
            //     }
            // }
            // /* on web platform, don't forward Ctrl-X, Ctrl-V to the browser */
            // if (_simgui_is_ctrl(ev->modifiers) && (ev->key_code == SAPP_KEYCODE_X)) {
            //     sapp_consume_event();
            // }
            // if (_simgui_is_ctrl(ev->modifiers) && (ev->key_code == SAPP_KEYCODE_C)) {
            //     sapp_consume_event();
            // }
            addKeyEvent(event.key_code, true);
        },
        .KEY_UP => {
            updateModifiers(event.modifiers);
            // TODO cut and paste
            // intercept Ctrl-V, this is handled via EVENTTYPE_CLIPBOARD_PASTED
            // if (_simgui_is_ctrl(ev->modifiers) && (ev->key_code == SAPP_KEYCODE_V)) {
            //     break;
            // }
            // /* on web platform, don't forward Ctrl-X, Ctrl-V to the browser */
            // if (_simgui_is_ctrl(ev->modifiers) && (ev->key_code == SAPP_KEYCODE_X)) {
            //     sapp_consume_event();
            // }
            // if (_simgui_is_ctrl(ev->modifiers) && (ev->key_code == SAPP_KEYCODE_C)) {
            //     sapp_consume_event();
            // }
            addKeyEvent(event.key_code, false);
        },
        .CHAR => {
            updateModifiers(event.modifiers);
            if ((event.char_code >= 32) and
                (event.char_code != 127) and
                (0 == (event.modifiers & (sapp.modifier_ctrl | sapp.modifier_alt | sapp.modifier_super))))
            {
                zgui.io.addCharacterEvent(@intCast(i32, event.char_code));
            }
        },
        .CLIPBOARD_PASTED => {
            // TODO cut and paste
        },
        else => {},
    }

    return zgui.io.getWantCaptureKeyboard() or zgui.io.getWantCaptureMouse();
}
