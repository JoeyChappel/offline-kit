#import "RetroCore.h"
#import <dlfcn.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <Accelerate/Accelerate.h>
#import "libretro.h"

// libretro callbacks have no context pointer, so they route through the one loaded core.
static __weak RetroCore *gCore = nil;

@interface RetroCore ()
- (void)deliverFrame:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch;
- (void)pushAudio:(const int16_t *)data frames:(NSInteger)frames;
@end

typedef struct {
    void (*init)(void);
    void (*deinit)(void);
    unsigned (*api_version)(void);
    void (*get_system_info)(struct retro_system_info *);
    void (*get_system_av_info)(struct retro_system_av_info *);
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*set_controller_port_device)(unsigned, unsigned);
    void (*reset)(void);
    void (*run)(void);
    size_t (*serialize_size)(void);
    bool (*serialize)(void *, size_t);
    bool (*unserialize)(const void *, size_t);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
} RetroAPI;

#define AUDIO_CAPACITY (48000 * 2)   // one second of stereo frames at 48 kHz, in samples x2
#define KEY_COUNT 512                 // covers RETROK_LAST
#define KEY_QUEUE 256

/// Pixel memory handed to a CGImage and taken back when the image is released, so a frame needs no allocation
/// once a few are in flight (the main thread keeps the last one for as long as it's on screen).
@class FramePool;
@interface FrameBuffer : NSObject {
@public
    void *bytes;
    size_t capacity;
    FramePool *pool;
}
@end
@interface FramePool : NSObject
- (FrameBuffer *)takeBytes:(size_t)size;
- (void)giveBack:(FrameBuffer *)buffer;
- (void)close;
@end

@implementation FrameBuffer
- (void)dealloc { free(bytes); }
@end

@implementation FramePool {
    os_unfair_lock _lock;
    NSMutableArray<FrameBuffer *> *_free;
    BOOL _closed;
}
- (instancetype)init {
    if ((self = [super init])) { _lock = OS_UNFAIR_LOCK_INIT; _free = [NSMutableArray array]; }
    return self;
}
- (FrameBuffer *)takeBytes:(size_t)size {
    FrameBuffer *found = nil;
    os_unfair_lock_lock(&_lock);
    while (_free.count > 0) {
        FrameBuffer *candidate = _free.lastObject;
        [_free removeLastObject];
        if (candidate->capacity == size) { found = candidate; break; }   // wrong size (the core changed mode): let it go
    }
    os_unfair_lock_unlock(&_lock);
    if (found) return found;
    FrameBuffer *buffer = [FrameBuffer new];
    buffer->bytes = malloc(size);
    buffer->capacity = size;
    buffer->pool = self;
    return buffer->bytes ? buffer : nil;
}
- (void)giveBack:(FrameBuffer *)buffer {
    os_unfair_lock_lock(&_lock);
    if (!_closed && _free.count < 4) [_free addObject:buffer];
    os_unfair_lock_unlock(&_lock);
}
- (void)close {
    os_unfair_lock_lock(&_lock);
    _closed = YES;
    [_free removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}
@end

static void ReleaseFrameBuffer(void *info, const void *data, size_t size) {
    FrameBuffer *buffer = (__bridge_transfer FrameBuffer *)info;
    [buffer->pool giveBack:buffer];
}

typedef struct { unsigned keycode; uint32_t character; uint16_t modifiers; bool down; } KeyEvent;

@implementation RetroCore {
    void *_handle;
    RetroAPI _api;
    BOOL _loaded;
    enum retro_pixel_format _format;
    char _systemDir[1024];
    char _saveDir[1024];
    NSData *_gameData;
    NSDictionary<NSString *, NSData *> *_options;   // NUL-terminated values, so the core can keep the pointers
    atomic_uint _buttons;
    atomic_uint _buttons2;             // player 2 (port 1), for a phone used as a second controller
    retro_keyboard_event_t _keyboardEvent;
    // Keyboard and mouse: written by the UI thread under _inputLock, taken by the emulation thread once per frame.
    os_unfair_lock _inputLock;
    KeyEvent _keyQueue[KEY_QUEUE];
    NSInteger _keyQueueCount;
    BOOL _releaseKeys;
    BOOL _pinMouse;
    bool _keyDown[KEY_COUNT];          // emulation thread only
    double _mouseAccX, _mouseAccY;
    NSInteger _wheelAcc;
    int16_t _mouseFrameX, _mouseFrameY, _wheelFrame;   // emulation thread only
    atomic_uint _mouseButtons;
    atomic_int _pointerX, _pointerY;
    atomic_bool _pointerPressed, _pointerActive;
    FramePool *_framePool;
    int16_t _audio[AUDIO_CAPACITY * 2];
    NSInteger _audioRead, _audioWrite, _audioCount;   // in frames
    os_unfair_lock _audioLock;
    CGColorSpaceRef _colorSpace;
}

#pragma mark Callbacks

static void LogCallback(enum retro_log_level level, const char *fmt, ...) {
#if DEBUG
    if (level < RETRO_LOG_WARN) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
#endif
}

static void ApplyAVInfo(RetroCore *core, const struct retro_system_av_info *av);

static bool EnvironmentCallback(unsigned cmd, void *data) {
    RetroCore *core = gCore;
    if (!core) return false;
    switch (cmd & 0xFFFF) {
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            enum retro_pixel_format f = *(const enum retro_pixel_format *)data;
            if (f == RETRO_PIXEL_FORMAT_0RGB1555 || f == RETRO_PIXEL_FORMAT_XRGB8888 || f == RETRO_PIXEL_FORMAT_RGB565) {
                core->_format = f;
                return true;
            }
            return false;
        }
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = core->_systemDir;
            return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = core->_saveDir;
            return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            *(bool *)data = true;
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *var = data;
            NSData *value = var->key ? core->_options[@(var->key)] : nil;
            var->value = value.bytes;
            return value != nil;
        }
        case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
            core->_keyboardEvent = ((const struct retro_keyboard_callback *)data)->callback;
            core->_wantsKeyboard = core->_keyboardEvent != NULL;
            return true;
        case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
            *(uint64_t *)data = (1 << RETRO_DEVICE_JOYPAD) | (1 << RETRO_DEVICE_MOUSE) | (1 << RETRO_DEVICE_KEYBOARD) | (1 << RETRO_DEVICE_POINTER);
            return true;
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
            ApplyAVInfo(core, data);
            return true;
        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            const struct retro_game_geometry *g = data;
            float aspect = g->aspect_ratio > 0 ? g->aspect_ratio : (float)g->base_width / (float)MAX(1u, g->base_height);
            if (aspect > 0) core->_aspectRatio = aspect;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MESSAGE: {
            const struct retro_message *m = data;
            if (m && m->msg && core.messageHandler) core.messageHandler(@(m->msg));
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
            const struct retro_message_ext *m = data;
            if (m && m->msg && m->level >= RETRO_LOG_WARN && core.messageHandler) core.messageHandler(@(m->msg));
            return true;
        }
        case RETRO_ENVIRONMENT_SHUTDOWN:
            core->_shutdownRequested = YES;
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            *(bool *)data = false;
            return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            ((struct retro_log_callback *)data)->log = LogCallback;
            return true;
        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            return true;
        case RETRO_ENVIRONMENT_GET_LANGUAGE:
            *(unsigned *)data = RETRO_LANGUAGE_ENGLISH;
            return true;
        case RETRO_ENVIRONMENT_SET_VARIABLES:
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
        case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
        case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
        case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
            return true;
        default:
            return false;
    }
}

static void VideoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    RetroCore *core = gCore;
    // NULL data means "repeat last frame"; RETRO_HW_FRAME_BUFFER_VALID means a GPU frame, which this frontend never offers.
    if (!core || !data || data == RETRO_HW_FRAME_BUFFER_VALID || width == 0 || height == 0) return;
    [core deliverFrame:data width:width height:height pitch:pitch];
}

static size_t AudioBatchCallback(const int16_t *data, size_t frames) {
    RetroCore *core = gCore;
    if (core) [core pushAudio:data frames:(NSInteger)frames];
    return frames;
}

static void AudioSampleCallback(int16_t left, int16_t right) {
    int16_t pair[2] = { left, right };
    AudioBatchCallback(pair, 1);
}

static void InputPollCallback(void) {}

static int16_t InputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    RetroCore *core = gCore;
    if (!core) return 0;
    if (port == 1 && (device & RETRO_DEVICE_MASK) == RETRO_DEVICE_JOYPAD) {
        unsigned mask = atomic_load(&core->_buttons2);
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)mask;
        return (mask >> id) & 1;
    }
    if (port != 0) return 0;
    switch (device & RETRO_DEVICE_MASK) {
        case RETRO_DEVICE_JOYPAD: {
            unsigned mask = atomic_load(&core->_buttons);
            if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)mask;
            return (mask >> id) & 1;
        }
        case RETRO_DEVICE_KEYBOARD:
            return id < KEY_COUNT && core->_keyDown[id];
        case RETRO_DEVICE_MOUSE:
            switch (id) {
                case RETRO_DEVICE_ID_MOUSE_X: return core->_mouseFrameX;
                case RETRO_DEVICE_ID_MOUSE_Y: return core->_mouseFrameY;
                case RETRO_DEVICE_ID_MOUSE_LEFT: return (atomic_load(&core->_mouseButtons) >> RetroMouseButtonLeft) & 1;
                case RETRO_DEVICE_ID_MOUSE_RIGHT: return (atomic_load(&core->_mouseButtons) >> RetroMouseButtonRight) & 1;
                case RETRO_DEVICE_ID_MOUSE_MIDDLE: return (atomic_load(&core->_mouseButtons) >> RetroMouseButtonMiddle) & 1;
                case RETRO_DEVICE_ID_MOUSE_WHEELUP: return core->_wheelFrame < 0;
                case RETRO_DEVICE_ID_MOUSE_WHEELDOWN: return core->_wheelFrame > 0;
                default: return 0;
            }
        case RETRO_DEVICE_POINTER:
            if (index != 0 || !atomic_load(&core->_pointerActive)) return 0;
            switch (id) {
                case RETRO_DEVICE_ID_POINTER_X: return (int16_t)atomic_load(&core->_pointerX);
                case RETRO_DEVICE_ID_POINTER_Y: return (int16_t)atomic_load(&core->_pointerY);
                case RETRO_DEVICE_ID_POINTER_PRESSED: return atomic_load(&core->_pointerPressed);
                case RETRO_DEVICE_ID_POINTER_COUNT: return atomic_load(&core->_pointerPressed) ? 1 : 0;
                default: return 0;
            }
        default:
            return 0;
    }
}

static void ApplyAVInfo(RetroCore *core, const struct retro_system_av_info *av) {
    if (av->timing.fps > 0) core->_framesPerSecond = av->timing.fps;
    if (av->timing.sample_rate > 0 && core->_sampleRate == 0) core->_sampleRate = av->timing.sample_rate;
    float aspect = av->geometry.aspect_ratio > 0 ? av->geometry.aspect_ratio
                 : (float)av->geometry.base_width / (float)MAX(1u, av->geometry.base_height);
    if (aspect > 0) core->_aspectRatio = aspect;
}

#pragma mark Lifecycle

static NSError *CoreError(NSString *message) {
    return [NSError errorWithDomain:@"RetroCore" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (instancetype)initWithLibraryPath:(NSString *)path error:(NSError **)error {
    return [self initWithLibraryPath:path options:nil systemDirectory:nil saveDirectory:nil error:error];
}

- (instancetype)initWithLibraryPath:(NSString *)path options:(NSDictionary<NSString *, NSString *> *)options
                    systemDirectory:(NSString *)systemDirectory saveDirectory:(NSString *)saveDirectory error:(NSError **)error {
    if (gCore) {
        if (error) *error = CoreError(@"Another game is already running. Close it first.");
        return nil;
    }
    if ((self = [super init])) {
        _handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
        if (!_handle) {
            if (error) *error = CoreError([NSString stringWithFormat:@"Couldn't load the emulator: %s", dlerror()]);
            return nil;
        }
#define LOAD(field, name) _api.field = dlsym(_handle, name); if (!_api.field) { \
            if (error) *error = CoreError(@"The emulator is missing " @name "."); dlclose(_handle); _handle = NULL; return nil; }
        LOAD(init, "retro_init")
        LOAD(deinit, "retro_deinit")
        LOAD(api_version, "retro_api_version")
        LOAD(get_system_info, "retro_get_system_info")
        LOAD(get_system_av_info, "retro_get_system_av_info")
        LOAD(set_environment, "retro_set_environment")
        LOAD(set_video_refresh, "retro_set_video_refresh")
        LOAD(set_audio_sample, "retro_set_audio_sample")
        LOAD(set_audio_sample_batch, "retro_set_audio_sample_batch")
        LOAD(set_input_poll, "retro_set_input_poll")
        LOAD(set_input_state, "retro_set_input_state")
        LOAD(set_controller_port_device, "retro_set_controller_port_device")
        LOAD(reset, "retro_reset")
        LOAD(run, "retro_run")
        LOAD(serialize_size, "retro_serialize_size")
        LOAD(serialize, "retro_serialize")
        LOAD(unserialize, "retro_unserialize")
        LOAD(load_game, "retro_load_game")
        LOAD(unload_game, "retro_unload_game")
        LOAD(get_memory_data, "retro_get_memory_data")
        LOAD(get_memory_size, "retro_get_memory_size")
#undef LOAD
        if (_api.api_version() != RETRO_API_VERSION) {
            if (error) *error = CoreError(@"The emulator uses an unsupported libretro version.");
            dlclose(_handle); _handle = NULL;
            return nil;
        }
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        [options enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            const char *utf8 = value.UTF8String;
            values[key] = [NSData dataWithBytes:utf8 length:strlen(utf8) + 1];
        }];
        _options = values;
        if (systemDirectory) strlcpy(_systemDir, systemDirectory.fileSystemRepresentation, sizeof(_systemDir));
        if (saveDirectory) strlcpy(_saveDir, saveDirectory.fileSystemRepresentation, sizeof(_saveDir));
        gCore = self;
        _portDevice = RETRO_DEVICE_JOYPAD;
        _format = RETRO_PIXEL_FORMAT_0RGB1555;
        _audioLock = OS_UNFAIR_LOCK_INIT;
        _inputLock = OS_UNFAIR_LOCK_INIT;
        _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        _framePool = [FramePool new];

        struct retro_system_info info = {0};
        _api.get_system_info(&info);
        _libraryName = info.library_name ? @(info.library_name) : @"";
        _libraryVersion = info.library_version ? @(info.library_version) : @"";
        _validExtensions = info.valid_extensions ? @(info.valid_extensions) : @"";

        _api.set_environment(EnvironmentCallback);
        _api.init();
        _api.set_video_refresh(VideoCallback);
        _api.set_audio_sample(AudioSampleCallback);
        _api.set_audio_sample_batch(AudioBatchCallback);
        _api.set_input_poll(InputPollCallback);
        _api.set_input_state(InputStateCallback);
    }
    return self;
}

- (void)dealloc {
    [self unloadGame];
    if (_handle) {
        _api.deinit();
        dlclose(_handle);
    }
    [_framePool close];
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (BOOL)loadGameAtPath:(NSString *)path systemDirectory:(NSString *)systemDirectory
         saveDirectory:(NSString *)saveDirectory error:(NSError **)error {
    strlcpy(_systemDir, systemDirectory.fileSystemRepresentation, sizeof(_systemDir));
    strlcpy(_saveDir, saveDirectory.fileSystemRepresentation, sizeof(_saveDir));
    // Folders (ScummVM games) and large files (DOS disk images) go by path only; the cores that take them read
    // the files themselves. Everything else is handed over in memory as before.
    BOOL isFolder = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isFolder]) {
        if (error) *error = CoreError(@"The game file is missing.");
        return NO;
    }
    struct retro_system_info info = {0};
    _api.get_system_info(&info);
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL] fileSize];
    if (!isFolder && !(info.need_fullpath && size > 64 * 1024 * 1024)) {
        _gameData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
        if (!_gameData) return NO;
    }

    struct retro_game_info game = {
        .path = path.fileSystemRepresentation,
        .data = _gameData.bytes,
        .size = _gameData.length,
        .meta = NULL,
    };
    if (!_api.load_game(&game)) {
        if (error) *error = CoreError(@"The emulator couldn't open this game file.");
        _gameData = nil;
        return NO;
    }
    _api.set_controller_port_device(0, _portDevice);
    struct retro_system_av_info av = {0};
    _api.get_system_av_info(&av);
    _sampleRate = 0;
    ApplyAVInfo(self, &av);
    if (_framesPerSecond <= 0) _framesPerSecond = 60;
    if (_sampleRate <= 0) _sampleRate = 48000;
    _loaded = YES;
    return YES;
}

- (void)unloadGame {
    if (!_loaded) return;
    _api.unload_game();
    _loaded = NO;
    _gameData = nil;
}

- (void)runFrame {
    if (!_loaded) return;
    [self takeQueuedInput];
    _api.run();
}
- (void)reset { if (_loaded) _api.reset(); }

#pragma mark Input

- (void)setButton:(RetroButton)button pressed:(BOOL)pressed {
    unsigned bit = 1u << (unsigned)button;
    if (pressed) atomic_fetch_or(&_buttons, bit);
    else atomic_fetch_and(&_buttons, ~bit);
}

- (void)setButton:(RetroButton)button pressed:(BOOL)pressed port:(unsigned)port {
    if (port == 0) { [self setButton:button pressed:pressed]; return; }
    if (port != 1) return;
    unsigned bit = 1u << (unsigned)button;
    if (pressed) atomic_fetch_or(&_buttons2, bit);
    else atomic_fetch_and(&_buttons2, ~bit);
}

- (void)releaseButtonsOnPort:(unsigned)port {
    if (port == 0) atomic_store(&_buttons, 0);
    else if (port == 1) atomic_store(&_buttons2, 0);
}

- (void)releaseAllButtons {
    atomic_store(&_buttons, 0);
    atomic_store(&_buttons2, 0);
    atomic_store(&_mouseButtons, 0);
    atomic_store(&_pointerPressed, false);
    // Lift held keys at the next frame (the key state belongs to the emulation thread).
    os_unfair_lock_lock(&_inputLock);
    _releaseKeys = YES;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setKey:(unsigned)keycode pressed:(BOOL)pressed character:(uint32_t)character modifiers:(uint16_t)modifiers {
    if (keycode == 0 || keycode >= KEY_COUNT) return;
    os_unfair_lock_lock(&_inputLock);
    if (_keyQueueCount < KEY_QUEUE) {
        _keyQueue[_keyQueueCount++] = (KeyEvent){ keycode, character, modifiers, pressed };
    }
    os_unfair_lock_unlock(&_inputLock);
}

- (void)moveMouseByX:(double)dx y:(double)dy {
    os_unfair_lock_lock(&_inputLock);
    _mouseAccX += dx;
    _mouseAccY += dy;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)pinMouseToCorner {
    os_unfair_lock_lock(&_inputLock);
    _pinMouse = YES;
    _mouseAccX = 0; _mouseAccY = 0;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setMouseButton:(RetroMouseButton)button pressed:(BOOL)pressed {
    unsigned bit = 1u << (unsigned)button;
    if (pressed) atomic_fetch_or(&_mouseButtons, bit);
    else atomic_fetch_and(&_mouseButtons, ~bit);
}

- (void)scrollMouseWheel:(NSInteger)notches {
    os_unfair_lock_lock(&_inputLock);
    _wheelAcc += notches;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setPointerX:(double)x y:(double)y pressed:(BOOL)pressed {
    atomic_store(&_pointerX, (int)lround(MAX(-1.0, MIN(1.0, x)) * 0x7fff));
    atomic_store(&_pointerY, (int)lround(MAX(-1.0, MIN(1.0, y)) * 0x7fff));
    atomic_store(&_pointerPressed, (bool)pressed);
    atomic_store(&_pointerActive, true);
}

/// On the emulation thread before each frame: hands queued keys to the core and fixes this frame's mouse motion.
- (void)takeQueuedInput {
    KeyEvent events[KEY_QUEUE];
    NSInteger count;
    BOOL release;
    os_unfair_lock_lock(&_inputLock);
    count = _keyQueueCount;
    memcpy(events, _keyQueue, sizeof(KeyEvent) * (size_t)count);
    _keyQueueCount = 0;
    release = _releaseKeys;
    _releaseKeys = NO;
    if (_pinMouse) {   // this frame only pins; moves made meanwhile wait for the next one
        _pinMouse = NO;
        _mouseFrameX = -32767;
        _mouseFrameY = -32767;
    } else {
        double mx = trunc(_mouseAccX), my = trunc(_mouseAccY);
        _mouseAccX -= mx; _mouseAccY -= my;
        _mouseFrameX = (int16_t)MAX(-32767.0, MIN(32767.0, mx));
        _mouseFrameY = (int16_t)MAX(-32767.0, MIN(32767.0, my));
    }
    _wheelFrame = _wheelAcc > 0 ? 1 : (_wheelAcc < 0 ? -1 : 0);
    _wheelAcc -= _wheelFrame;
    os_unfair_lock_unlock(&_inputLock);

    for (NSInteger i = 0; i < count; i++) {
        KeyEvent e = events[i];
        _keyDown[e.keycode] = e.down;
        if (_keyboardEvent) _keyboardEvent(e.down, e.keycode, e.character, e.modifiers);
    }
    if (release) {
        for (unsigned k = 0; k < KEY_COUNT; k++) {
            if (!_keyDown[k]) continue;
            _keyDown[k] = false;
            if (_keyboardEvent) _keyboardEvent(false, k, 0, 0);
        }
    }
}

#pragma mark Video

- (void)deliverFrame:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch {
    void (^handler)(CGImageRef) = self.frameHandler;
    if (!handler) return;
    size_t rowBytes = (size_t)width * 4;
    FrameBuffer *buffer = [_framePool takeBytes:rowBytes * height];
    if (!buffer) return;
    // One pass from the core's memory into the buffer the image will own. 16-bit formats become ARGB8888 (big-endian
    // byte order); the core's own XRGB8888 is already BGRA in memory on little-endian CPUs.
    vImage_Buffer src = { (void *)data, height, width, pitch };
    vImage_Buffer dst = { buffer->bytes, height, width, rowBytes };
    CGBitmapInfo info = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
    switch (_format) {
        case RETRO_PIXEL_FORMAT_XRGB8888:
            if (pitch == rowBytes) memcpy(buffer->bytes, data, rowBytes * height);
            else vImageCopyBuffer(&src, &dst, 4, kvImageDoNotTile);
            break;
        case RETRO_PIXEL_FORMAT_RGB565:
            vImageConvert_RGB565toARGB8888(255, &src, &dst, kvImageDoNotTile);
            info = kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
            break;
        default:   // 0RGB1555
            vImageConvert_ARGB1555toARGB8888(&src, &dst, kvImageDoNotTile);
            info = kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
            break;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData((__bridge_retained void *)buffer, buffer->bytes,
                                                              rowBytes * height, ReleaseFrameBuffer);
    CGImageRef image = CGImageCreate(width, height, 8, 32, rowBytes, _colorSpace, info,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    if (image) handler(image);
    CGImageRelease(image);
    CGDataProviderRelease(provider);
}

- (void)clearAudio {
    os_unfair_lock_lock(&_audioLock);
    _audioRead = _audioWrite = _audioCount = 0;
    os_unfair_lock_unlock(&_audioLock);
}

#pragma mark Audio

- (void)pushAudio:(const int16_t *)data frames:(NSInteger)frames {
    os_unfair_lock_lock(&_audioLock);
    for (NSInteger i = 0; i < frames; i++) {
        if (_audioCount == AUDIO_CAPACITY) {   // full: drop the oldest frame
            _audioRead = (_audioRead + 1) % AUDIO_CAPACITY;
            _audioCount--;
        }
        _audio[_audioWrite * 2] = data[i * 2];
        _audio[_audioWrite * 2 + 1] = data[i * 2 + 1];
        _audioWrite = (_audioWrite + 1) % AUDIO_CAPACITY;
        _audioCount++;
    }
    os_unfair_lock_unlock(&_audioLock);
}

- (NSInteger)readAudio:(int16_t *)buffer frames:(NSInteger)frames {
    os_unfair_lock_lock(&_audioLock);
    NSInteger n = MIN(frames, _audioCount);
    for (NSInteger i = 0; i < n; i++) {
        buffer[i * 2] = _audio[_audioRead * 2];
        buffer[i * 2 + 1] = _audio[_audioRead * 2 + 1];
        _audioRead = (_audioRead + 1) % AUDIO_CAPACITY;
    }
    _audioCount -= n;
    os_unfair_lock_unlock(&_audioLock);
    if (n < frames) memset(buffer + n * 2, 0, (size_t)(frames - n) * 2 * sizeof(int16_t));
    return n;
}

- (NSInteger)queuedAudioFrames {
    os_unfair_lock_lock(&_audioLock);
    NSInteger n = _audioCount;
    os_unfair_lock_unlock(&_audioLock);
    return n;
}

#pragma mark Saves

- (BOOL)supportsSaveStates { return _loaded && _api.serialize_size() > 0; }

- (NSData *)serializeState {
    if (!_loaded) return nil;
    size_t size = _api.serialize_size();
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    return _api.serialize(data.mutableBytes, size) ? data : nil;
}

- (BOOL)unserializeState:(NSData *)state {
    return _loaded && _api.unserialize(state.bytes, state.length);
}

- (NSData *)saveRAM {
    if (!_loaded) return nil;
    void *ptr = _api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = _api.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    return (ptr && size) ? [NSData dataWithBytes:ptr length:size] : nil;
}

- (void)restoreSaveRAM:(NSData *)data {
    if (!_loaded) return;
    void *ptr = _api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = _api.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (ptr && size) memcpy(ptr, data.bytes, MIN(size, data.length));
}

@end
