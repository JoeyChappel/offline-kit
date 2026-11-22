#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZimHit : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *snippet;
@property (nonatomic) NSInteger score;
@end

@interface ZimContent : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, copy) NSString *mimeType;
/// Final path after following redirects.
@property (nonatomic, copy) NSString *path;
/// Size of the whole entry in bytes (the data may hold only part of it; see -dataAtPath:offset:length:).
@property (nonatomic) NSUInteger totalSize;
@end

/// One article read for the answer index: its own path (articles are never redirects) and title, and the start of its HTML.
@interface ZimArticle : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSData *html;
@end

/// Thin Objective-C++ wrapper over libzim. Instances are safe to read from
/// multiple threads; libzim archives are immutable once opened.
@interface ZimArchive : NSObject

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *uuid;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *summary;
@property (nonatomic, readonly, copy) NSString *language;
@property (nonatomic, readonly, copy) NSString *creator;
@property (nonatomic, readonly) NSUInteger articleCount;
/// Every entry: articles, images, styles and the rest.
@property (nonatomic, readonly) NSUInteger entryCount;
@property (nonatomic, readonly) BOOL hasFullTextIndex;
@property (nonatomic, readonly, copy, nullable) NSString *mainPagePath;
@property (nonatomic, readonly, nullable) NSData *illustration;

/// Full-text (Xapian) search. Returns an empty array if the archive has no index.
- (NSArray<ZimHit *> *)search:(NSString *)query limit:(NSInteger)limit;
/// Same, without snippets for hits whose paths are in `known` (their snippet is empty): making one reads the article.
- (NSArray<ZimHit *> *)search:(NSString *)query limit:(NSInteger)limit snippetsExcept:(nullable NSSet<NSString *> *)known;
/// Title suggestions, works on every archive.
- (NSArray<ZimHit *> *)suggest:(NSString *)query limit:(NSInteger)limit;
/// Every entry (not redirects) whose type starts with mimePrefix, e.g. @"application/pdf". Path and title only.
- (NSArray<ZimHit *> *)entriesWithMimePrefix:(NSString *)mimePrefix limit:(NSInteger)limit;
/// Entry content, following redirects. nil if the path doesn't exist.
- (nullable ZimContent *)contentAtPath:(NSString *)path;
/// Type, size and final path of an entry (following redirects) without reading its data: `data` is empty.
- (nullable ZimContent *)infoAtPath:(NSString *)path;
/// Only `length` bytes of the entry's data from `offset` (cut to the entry's end), for byte-range requests such as
/// seeking in a video. Pass the final path from -infoAtPath:. nil if the path doesn't exist.
- (nullable NSData *)dataAtPath:(NSString *)path offset:(NSUInteger)offset length:(NSUInteger)length;
- (nullable NSString *)metadata:(NSString *)key;
/// HTML articles in the order they're stored (so each compressed cluster is read once): the `count` entries from
/// position `start` (0-based, below entryCount), with at most `maxBytes` of each one's HTML. Redirects and entries
/// that aren't HTML are left out but still use up their position, so a caller can resume from `start + count`.
- (NSArray<ZimArticle *> *)articlesFrom:(NSUInteger)start count:(NSUInteger)count maxBytes:(NSUInteger)maxBytes;

@end

NS_ASSUME_NONNULL_END
