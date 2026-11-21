#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Joypad buttons, numbered like RETRO_DEVICE_ID_JOYPAD_*.
typedef NS_ENUM(NSInteger, RetroButton) {
    RetroButtonB = 0,
    RetroButtonY = 1,
    RetroButtonSelect = 2,
    RetroButtonStart = 3,
    RetroButtonUp = 4,
    RetroButtonDown = 5,
    RetroButtonLeft = 6,
    RetroButtonRight = 7,
    RetroButtonA = 8,
    RetroButtonX = 9,
    RetroButtonL = 10,
    RetroButtonR = 11,
};

/// Mouse buttons, numbered for the libretro mouse device.
typedef NS_ENUM(NSInteger, RetroMouseButton) {
    RetroMouseButtonLeft = 0,
    RetroMouseButtonRight = 1,
    RetroMouseButtonMiddle = 2,
};

/// One libretro emulator core loaded from a dynamic framework. Only one can be loaded at a time
/// (libretro callbacks carry no context), so creating a second one fails until the first is released.
@interface RetroCore : NSObject

/// `options` answers the core's settings questions (libretro core option key -> value); anything missing uses the core's default.
/// The folders are known from the start, since some cores (ScummVM) ask for them while initializing.
- (nullable instancetype)initWithLibraryPath:(NSString *)path
                                     options:(nullable NSDictionary<NSString *, NSString *> *)options
                             systemDirectory:(nullable NSString *)systemDirectory
                               saveDirectory:(nullable NSString *)saveDirectory
                                       error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithLibraryPath:(NSString *)path error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *libraryName;
@property (nonatomic, readonly, copy) NSString *libraryVersion;
@property (nonatomic, readonly, copy) NSString *validExtensions;

/// Valid after a game loads. The frame rate can change while a game runs (DOS games switch video modes).
@property (atomic, readonly) double framesPerSecond;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) float aspectRatio;

/// The controller type for player 1, set before loadGame (libretro device ID). Defaults to the plain joypad (1).
/// DOS games that need a joystick use RETRO_DEVICE_SUBCLASS(JOYPAD, 4), DOSBox Pure's "First 2 Button Joystick".
@property (nonatomic) unsigned portDevice;

/// True once the core asked to close (RETRO_ENVIRONMENT_SHUTDOWN): the game quit, e.g. a DOS program exited.
/// Stop running frames when this turns true.
@property (atomic, readonly) BOOL shutdownRequested;

/// True when the core can save and restore its whole state (ScummVM can't; it saves from the game's own menu).
@property (nonatomic, readonly) BOOL supportsSaveStates;

- (BOOL)loadGameAtPath:(NSString *)path
       systemDirectory:(NSString *)systemDirectory
         saveDirectory:(NSString *)saveDirectory
                 error:(NSError **)error;
- (void)unloadGame;

/// Runs one frame. Call from a single background thread.
- (void)runFrame;
- (void)reset;

/// Called on the emulation thread with each new frame (32-bit BGRA, opaque).
@property (nonatomic, copy, nullable) void (^frameHandler)(CGImageRef image);

/// Short messages from the core ("Game not found"), on the emulation thread.
@property (nonatomic, copy, nullable) void (^messageHandler)(NSString *message);

- (void)setButton:(RetroButton)button pressed:(BOOL)pressed;
/// Releases joypad buttons, held keys and mouse buttons.
- (void)releaseAllButtons;

/// True once the core asked for keyboard events (DOS and ScummVM do).
@property (atomic, readonly) BOOL wantsKeyboard;
/// A key went down or up. `keycode` is a libretro key code (RETROK_*), `character` the typed character (0 if none),
/// `modifiers` libretro modifier flags (RETROKMOD_*). Delivered to the core at the start of the next frame.
- (void)setKey:(unsigned)keycode pressed:(BOOL)pressed character:(uint32_t)character modifiers:(uint16_t)modifiers;
/// Relative mouse movement, in game pixels.
- (void)moveMouseByX:(double)dx y:(double)dy;
/// Sends the game's cursor to the top-left corner, in a frame of its own, so later moves can track an absolute position.
- (void)pinMouseToCorner;
- (void)setMouseButton:(RetroMouseButton)button pressed:(BOOL)pressed;
/// Scroll wheel notches; negative is up.
- (void)scrollMouseWheel:(NSInteger)notches;
/// Absolute pointer or touch, with x and y each from -1 (left / top) to 1 (right / bottom) across the picture.
- (void)setPointerX:(double)x y:(double)y pressed:(BOOL)pressed;

/// Pulls interleaved stereo int16 samples queued by the core. Returns frames copied; the rest is silence.
- (NSInteger)readAudio:(int16_t *)buffer frames:(NSInteger)frames;
/// Frames of audio waiting, for pacing.
@property (nonatomic, readonly) NSInteger queuedAudioFrames;

- (nullable NSData *)serializeState;
- (BOOL)unserializeState:(NSData *)state;
/// Battery-backed save memory (in-game saves), or nil if the game has none.
- (nullable NSData *)saveRAM;
- (void)restoreSaveRAM:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
