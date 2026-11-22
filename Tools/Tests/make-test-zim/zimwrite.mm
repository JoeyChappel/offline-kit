// Writes a ZIM archive from a records file, using the libzim writer inside the vendored CoreKiwix.
// Test data only: Offline Kit never writes archives.
//
// usage: zimwrite <records> <out.zim> <name> <title> <description> [noindex]
// records: articles separated by \x1e, fields by \x1f: path \x1f title \x1f html
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <zim/writer/creator.h>
#include <zim/writer/item.h>

int main(int argc, char **argv) {
    if (argc < 6) {
        std::cerr << "usage: zimwrite <records> <out.zim> <name> <title> <description> [noindex]\n";
        return 2;
    }
    std::ifstream in(argv[1], std::ios::binary);
    std::stringstream buffer;
    buffer << in.rdbuf();
    const std::string all = buffer.str();
    const bool index = !(argc > 6 && std::string(argv[6]) == "noindex");

    zim::writer::Creator creator;
    creator.configIndexing(index, "eng").configNbWorkers(4).configClusterSize(2 << 20);
    creator.startZimCreation(argv[2]);
    size_t start = 0, count = 0;
    std::string firstPath;
    while (start < all.size()) {
        size_t end = all.find('\x1e', start);
        if (end == std::string::npos) end = all.size();
        const std::string record = all.substr(start, end - start);
        start = end + 1;
        size_t a = record.find('\x1f'), b = record.find('\x1f', a + 1);
        if (a == std::string::npos || b == std::string::npos) continue;
        const std::string path = record.substr(0, a), title = record.substr(a + 1, b - a - 1), html = record.substr(b + 1);
        if (firstPath.empty()) firstPath = path;
        zim::writer::Hints hints;
        hints[zim::writer::FRONT_ARTICLE] = 1;
        creator.addItem(zim::writer::StringItem::create(path, "text/html", title, hints, html));
        ++count;
    }
    creator.setMainPath(firstPath);
    creator.addMetadata("Title", argv[4]);
    creator.addMetadata("Name", argv[3]);
    creator.addMetadata("Description", argv[5]);
    creator.addMetadata("Language", "eng");
    creator.addMetadata("Creator", "Offline Kit test data");
    creator.addMetadata("Publisher", "Offline Kit test data");
    creator.addMetadata("Date", "2026-11-21");
    creator.finishZimCreation();
    std::cout << "wrote " << count << " articles to " << argv[2] << (index ? " (full-text index)" : "") << "\n";
    return 0;
}
