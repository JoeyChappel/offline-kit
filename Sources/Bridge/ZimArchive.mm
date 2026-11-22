#import "ZimArchive.h"

#include <memory>
#include <string>
#include <zim/archive.h>
#include <zim/entry.h>
#include <zim/item.h>
#include <zim/search.h>
#include <zim/suggestion.h>
#include <zim/error.h>

static NSString *S(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

@implementation ZimHit
@end

@implementation ZimContent
@end

@implementation ZimArticle
@end

@implementation ZimArchive {
    std::unique_ptr<zim::Archive> _archive;
}

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    if ((self = [super init])) {
        try {
            _archive = std::make_unique<zim::Archive>(std::string(path.fileSystemRepresentation));
        } catch (const std::exception &e) {
            if (error) {
                *error = [NSError errorWithDomain:@"ZimArchive" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: S(e.what())}];
            }
            return nil;
        }
        _path = [path copy];
        _uuid = S(static_cast<std::string>(_archive->getUuid()));
        _title = [self metadata:@"Title"] ?: path.lastPathComponent.stringByDeletingPathExtension;
        _name = [self metadata:@"Name"] ?: @"";
        _summary = [self metadata:@"Description"] ?: @"";
        _language = [self metadata:@"Language"] ?: @"";
        _creator = [self metadata:@"Creator"] ?: @"";
        _articleCount = _archive->getArticleCount();
        _entryCount = _archive->getEntryCount();
        _hasFullTextIndex = _archive->hasFulltextIndex();
        try {
            if (_archive->hasMainEntry()) {
                _mainPagePath = S(_archive->getMainEntry().getItem(true).getPath());
            }
        } catch (...) {}
        try {
            if (_archive->hasIllustration(48)) {
                zim::Blob b = _archive->getIllustrationItem(48).getData();
                _illustration = [NSData dataWithBytes:b.data() length:b.size()];
            }
        } catch (...) {}
    }
    return self;
}

- (nullable NSString *)metadata:(NSString *)key {
    try {
        std::string v = _archive->getMetadata(std::string(key.UTF8String));
        return v.empty() ? nil : S(v);
    } catch (...) {
        return nil;
    }
}

- (NSArray<ZimHit *> *)search:(NSString *)query limit:(NSInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    if (!_hasFullTextIndex || query.length == 0) return out;
    try {
        zim::Searcher searcher(*_archive);
        zim::Query q(std::string(query.UTF8String));
        auto search = searcher.search(q);
        auto results = search.getResults(0, (int)limit);
        for (auto it = results.begin(); it != results.end(); ++it) {
            ZimHit *h = [ZimHit new];
            h.path = S(it.getPath());
            h.title = S(it.getTitle());
            try { h.snippet = S(it.getSnippet()); } catch (...) { h.snippet = @""; }
            h.score = it.getScore();
            [out addObject:h];
        }
    } catch (...) {}
    return out;
}

- (NSArray<ZimHit *> *)suggest:(NSString *)query limit:(NSInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    if (query.length == 0) return out;
    try {
        zim::SuggestionSearcher searcher(*_archive);
        auto search = searcher.suggest(std::string(query.UTF8String));
        auto results = search.getResults(0, (int)limit);
        for (auto it = results.begin(); it != results.end(); ++it) {
            ZimHit *h = [ZimHit new];
            h.path = S(it->getPath());
            h.title = S(it->getTitle());
            h.snippet = S(it->getSnippet());
            h.score = 0;
            [out addObject:h];
        }
    } catch (...) {}
    return out;
}

- (NSArray<ZimArticle *> *)articlesFrom:(NSUInteger)start count:(NSUInteger)count maxBytes:(NSUInteger)maxBytes {
    NSMutableArray *out = [NSMutableArray array];
    if (start >= _entryCount || count == 0) return out;
    try {
        for (const auto &entry : _archive->iterEfficient().offset((int)start, (int)count)) {
            if (entry.isRedirect()) continue;
            try {
                zim::Item item = entry.getItem();
                if (item.getMimetype().rfind("text/html", 0) != 0) continue;
                zim::size_type size = item.getSize();
                zim::Blob blob = item.getData(0, MIN(size, (zim::size_type)maxBytes));
                ZimArticle *a = [ZimArticle new];
                a.path = S(item.getPath());
                a.title = S(entry.getTitle());
                a.html = [NSData dataWithBytes:blob.data() length:blob.size()];
                [out addObject:a];
            } catch (...) { continue; }
        }
    } catch (...) {}
    return out;
}

- (NSArray<ZimHit *> *)entriesWithMimePrefix:(NSString *)mimePrefix limit:(NSInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    std::string prefix(mimePrefix.UTF8String);
    try {
        for (const auto &entry : _archive->iterByPath()) {
            if ((NSInteger)out.count >= limit) break;
            if (entry.isRedirect()) continue;
            try {
                if (entry.getItem().getMimetype().rfind(prefix, 0) != 0) continue;
            } catch (...) { continue; }
            ZimHit *h = [ZimHit new];
            h.path = S(entry.getPath());
            h.title = S(entry.getTitle());
            h.snippet = @"";
            h.score = 0;
            [out addObject:h];
        }
    } catch (...) {}
    return out;
}

- (nullable ZimContent *)contentAtPath:(NSString *)path {
    try {
        zim::Entry entry = _archive->getEntryByPath(std::string(path.UTF8String));
        zim::Item item = entry.getItem(true);
        zim::Blob blob = item.getData();
        ZimContent *c = [ZimContent new];
        c.data = [NSData dataWithBytes:blob.data() length:blob.size()];
        c.mimeType = S(item.getMimetype());
        c.path = S(item.getPath());
        c.totalSize = blob.size();
        return c;
    } catch (...) {
        return nil;
    }
}

- (nullable ZimContent *)infoAtPath:(NSString *)path {
    try {
        zim::Entry entry = _archive->getEntryByPath(std::string(path.UTF8String));
        zim::Item item = entry.getItem(true);
        ZimContent *c = [ZimContent new];
        c.data = [NSData data];
        c.mimeType = S(item.getMimetype());
        c.path = S(item.getPath());
        c.totalSize = item.getSize();
        return c;
    } catch (...) {
        return nil;
    }
}

- (nullable NSData *)dataAtPath:(NSString *)path offset:(NSUInteger)offset length:(NSUInteger)length {
    try {
        zim::Entry entry = _archive->getEntryByPath(std::string(path.UTF8String));
        zim::Item item = entry.getItem(true);
        zim::size_type total = item.getSize();
        if (offset >= total) return [NSData data];
        zim::size_type count = MIN((zim::size_type)length, total - (zim::size_type)offset);
        zim::Blob blob = item.getData((zim::offset_type)offset, count);
        return [NSData dataWithBytes:blob.data() length:blob.size()];
    } catch (...) {
        return nil;
    }
}

@end
