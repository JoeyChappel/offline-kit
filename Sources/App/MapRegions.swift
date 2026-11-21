import SwiftUI

/// Every map the Kiwix library publishes, organized by continent.
enum MapRegions {
    /// Whole-continent and whole-world maps, shown above the continent lists.
    static let wholeContinents = ["all", "north-america", "south-america", "europe", "africa", "asia", "australia-oceania"]

    /// Continent for each map, by the part of its name after "maps_en_". Regional groups sit with their continent.
    static let continents: [(title: String, slugs: Set<String>)] = [
        ("North America", ["united-states-of-america", "canada", "greenland", "central-america", "bahamas", "belize",
                           "costa-rica", "cuba", "el-salvador", "guatemala", "haiti-and-dominican-republic", "honduras",
                           "jamaica", "nicaragua", "panama", "ile-de-clipperton"]),
        ("South America", ["andes", "argentina", "bolivia", "brazil", "chile", "colombia", "ecuador", "guyana",
                           "paraguay", "peru", "suriname", "uruguay", "venezuela"]),
        ("Europe", ["balkans", "nordics", "albania", "andorra", "austria", "azores", "belarus", "belgium",
                    "bosnia-herzegovina", "bulgaria", "croatia", "cyprus", "czech-republic", "denmark", "estonia",
                    "faroe-islands", "france", "georgia", "germany", "greece", "guernsey-and-jersey", "hungary",
                    "isle-of-man", "italy", "kosovo", "latvia", "liechtenstein", "luxembourg", "macedonia", "malta",
                    "montenegro", "netherlands", "norway", "poland", "romania", "russia", "serbia", "slovakia",
                    "slovenia", "sweden", "switzerland", "turkey", "united-kingdom"]),
        ("Africa", ["southern-africa", "south-atlantic", "algeria", "angola", "benin", "botswana", "burkina-faso",
                    "burundi", "cameroon", "canary-islands", "cape-verde", "central-african-republic", "chad", "comores",
                    "congo-democratic-republic-kinshasa", "congo-republic-brazzaville", "djibouti", "egypt",
                    "equatorial-guinea", "eritrea", "ethiopia", "gabon", "ghana", "guinea", "guinea-bissau",
                    "ivory-coast", "kenya", "lesotho", "liberia", "libya", "madagascar", "malawi", "mali",
                    "mauritania", "mauritius", "morocco", "mozambique", "namibia", "niger", "nigeria", "rwanda",
                    "sao-tome-and-principe", "senegal-and-gambia", "seychelles", "sierra-leone", "somalia",
                    "south-africa", "south-sudan", "sudan", "swaziland", "tanzania", "togo", "tunisia", "uganda",
                    "zambia", "zimbabwe"]),
        ("Asia", ["southeast-asia", "gcc-states", "afghanistan", "armenia", "azerbaijan", "bangladesh", "bhutan",
                  "cambodia", "china", "east-timor", "indonesia-with-east-timor", "iran", "iraq", "israel-and-palestine",
                  "jordan", "kazakhstan", "kyrgyzstan", "laos", "lebanon", "malaysia-singapore-and-brunei", "maldives",
                  "mongolia", "myanmar-burma", "nepal", "north-korea", "pakistan", "philippines", "south-korea",
                  "sri-lanka", "syria", "taiwan", "tajikistan", "thailand", "turkmenistan", "uzbekistan", "vietnam",
                  "yemen"]),
        ("Australia and Oceania", ["australia", "new-zealand", "cook-islands", "fiji", "french-polynesia", "kiribati",
                                   "marshall-islands", "micronesia", "nauru", "new-caledonia", "niue", "palau",
                                   "papua-new-guinea", "pitcairn-islands", "samoa", "solomon-islands", "tokelau",
                                   "tonga", "tuvalu", "vanuatu", "wallis-et-futuna"]),
    ]

    static func slug(_ name: String) -> String { String(name.dropFirst("maps_en_".count)) }

    /// Latest entry for each map in the catalog.
    static func entries(in catalog: Catalog) -> [CatalogEntry] {
        Set(catalog.entries.map(\.name).filter { $0.hasPrefix("maps_en_") })
            .compactMap { catalog.entry(for: $0, pictures: .full) }
    }

    /// Continent sections in display order. Maps not listed above (new in the catalog) go under "Other places".
    static func sections(_ entries: [CatalogEntry]) -> [(title: String, entries: [CatalogEntry])] {
        let wholes = Set(wholeContinents)
        let maps = entries.filter { !wholes.contains(slug($0.name)) }
        let byTitle: (CatalogEntry, CatalogEntry) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var sections = continents.map { continent in
            (title: continent.title, entries: maps.filter { continent.slugs.contains(slug($0.name)) }.sorted(by: byTitle))
        }
        let known = continents.reduce(Set<String>()) { $0.union($1.slugs) }
        let other = maps.filter { !known.contains(slug($0.name)) }.sorted(by: byTitle)
        if !other.isEmpty { sections.append((title: "Other places", entries: other)) }
        return sections.filter { !$0.entries.isEmpty }
    }
}

/// Pick the countries you want, browsing by continent or searching by name.
struct MapRegionsCard: View {
    let catalog: Catalog
    @Binding var selected: Set<String>
    let status: (String) -> PackStatus?
    @State private var query = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        let all = MapRegions.entries(in: catalog)
        let wholes = MapRegions.wholeContinents.compactMap { slug in all.first { MapRegions.slug($0.name) == slug } }
        let sections = MapRegions.sections(all)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "map")
                    .font(.title3).foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maps").font(.headline)
                    Text("Street maps you can browse offline. Pick the countries you need; one country downloads much faster than a whole continent.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("Search countries, like Canada or Germany", text: $query)
                .textFieldStyle(.roundedBorder)
            Divider()
            if query.isEmpty {
                ForEach(sections, id: \.title) { section in
                    continentGroup(section.title, section.entries)
                }
                Divider()
                Text("Whole continents").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                rows(wholes)
            } else {
                let found = (wholes + sections.flatMap(\.entries)).filter { $0.title.localizedCaseInsensitiveContains(query) }
                if found.isEmpty {
                    Text("No map matches “\(query)”. Some countries only come as part of their continent.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                rows(found)
            }
            Text("Maps come from OpenStreetMap through the Kiwix library. © OpenStreetMap contributors.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 18)
        .onAppear {
            #if DEBUG
            // Test hook: -expandMaps "North America" opens that continent.
            if let open = UserDefaults.standard.string(forKey: "expandMaps") { expanded.insert(open) }
            #endif
            // Open any continent that already has something picked or downloading.
            for section in sections where section.entries.contains(where: { selected.contains($0.name) || status($0.name) != nil }) {
                expanded.insert(section.title)
            }
        }
    }

    private func continentGroup(_ title: String, _ entries: [CatalogEntry]) -> some View {
        let picked = entries.filter { selected.contains($0.name) }.count
        let isOpen = expanded.contains(title)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { if isOpen { expanded.remove(title) } else { expanded.insert(title) } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 16)
                    Text(title).font(.body.weight(.semibold))
                    Spacer()
                    Text(picked > 0 ? "\(picked) selected" : "\(entries.count) maps")
                        .font(.callout).foregroundStyle(picked > 0 ? Color.accentColor : .secondary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the \(title) maps" : "Shows the \(title) maps")
            if isOpen {
                VStack(alignment: .leading, spacing: 0) { rows(entries) }
                    .padding(.leading, 26).padding(.bottom, 6)
            }
        }
    }

    private func rows(_ entries: [CatalogEntry]) -> some View {
        ForEach(entries) { entry in
            RegionRow(entry: entry, isOn: selected.contains(entry.name), status: status(entry.name)) {
                if selected.contains(entry.name) { selected.remove(entry.name) } else { selected.insert(entry.name) }
            }
        }
    }
}

private struct RegionRow: View {
    let entry: CatalogEntry
    let isOn: Bool
    let status: PackStatus?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(status == nil && isOn ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
                Text(entry.title)
                Spacer(minLength: 12)
                switch status {
                case .installed:
                    Pill(text: "Installed", symbol: "checkmark", tint: .accentColor)
                case .downloading(let fraction, let paused):
                    Pill(text: paused ? "Paused" : "\(Int(fraction * 100))%", symbol: "arrow.down", tint: .accentColor)
                case nil:
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status != nil)
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case nil: isOn ? "checkmark.square.fill" : "square"
        }
    }
}
