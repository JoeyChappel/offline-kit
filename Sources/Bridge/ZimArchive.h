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
@property (nonatomic, readonly) BOOL hasFullTextIndex;
@property (nonatomic, readonly, copy, nullable) NSString *mainPagePath;
@property (nonatomic, readonly, nullable) NSData *illustration;

/// Full-text (Xapian) search. Returns an empty array if the archive has no index.
- (NSArray<ZimHit *> *)search:(NSString *)query limit:(NSInteger)limit;
/// Title suggestions, works on every archive.
- (NSArray<ZimHit *> *)suggest:(NSString *)query limit:(NSInteger)limit;
/// Every entry (not redirects) whose type starts with mimePrefix, e.g. @"application/pdf". Path and title only.
- (NSArray<ZimHit *> *)entriesWithMimePrefix:(NSString *)mimePrefix limit:(NSInteger)limit;
/// Entry content, following redirects. nil if the path doesn't exist.
- (nullable ZimContent *)contentAtPath:(NSString *)path;
- (nullable NSString *)metadata:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
