import Foundation

/// HTML for everything Offline Kit prints. Black on white, real text, no backgrounds needed, so it reads well
/// from any printer and photocopies cleanly.
enum PrintDocuments {
    static let privateWarning = "Printouts hold private medical details. Keep them somewhere safe, and shred old copies."

    // MARK: Wallet cards

    /// One fold-over card per person: cut on the solid line, fold on the dashed line, and it's credit-card size.
    static func walletCards(_ data: HouseholdData) -> String {
        let people = data.people
        var body = """
        <div class="sheet-note"><b>Wallet cards.</b> Print at 100% (Actual Size), not “Scale to fit”. Cut along the solid lines, fold on the
        dashed line, then laminate or tape. Each folded card is credit-card size (3.375 × 2.125 in).<br><span class="warn">\(esc(privateWarning))</span></div>
        """
        if people.isEmpty { body += "<p>No people added yet.</p>" }
        for person in people {
            let card = data.card(for: person)
            body += """
            <div class="pair">
              <div class="wcard front" data-name="\(esc(name(person)))">
                <div class="wtitle">EMERGENCY INFO</div>
                <div class="wname">\(esc(name(person)))</div>
                <div class="wline">\(join([card.birthDateText.isEmpty ? "" : "Born " + card.birthDateText,
                                            card.bloodType.isEmpty ? "" : "Blood type <b>\(esc(card.bloodType))</b>"], html: true))</div>
                \(line("Allergies", card.allergies, strong: true))
                \(line("Conditions", card.conditions))
                \(line("Medicines", card.medications.filter { !$0.name.isBlank }.map(\.line).joined(separator: "; ")))
              </div>
              <div class="wcard back" data-name="\(esc(name(person)))">
                <div class="wtitle">IN AN EMERGENCY, CALL</div>
                \(card.emergencyContacts.filter { !$0.isEmpty }.prefix(3).map { contactLine($0) }.joined())
                \(card.doctors.filter { !$0.isEmpty }.prefix(2).map { contactLine($0, prefix: "Doctor") }.joined())
                \(card.pharmacy.isEmpty ? "" : contactLine(card.pharmacy, prefix: "Pharmacy"))
                \(card.insurance.isEmpty ? "" : lineHTML("Insurance", insuranceHTML(card.insurance)))
                \(outOfArea(data).isEmpty ? "" : lineHTML("Out-of-area contact", outOfAreaHTML(data)))
                \(meetingText(data).isEmpty ? "" : line("Meet", meetingText(data)))
              </div>
            </div>
            """
        }
        return page(title: "Wallet cards", css: walletCSS, body: body, script: walletFitScript)
    }

    // MARK: One-page plan

    static func familyPlan(_ data: HouseholdData) -> String {
        page(title: "Family emergency plan", css: planCSS, body: planBody(data), script: fitScript)
    }

    private static func planBody(_ data: HouseholdData) -> String {
        let plan = data.extra.plan
        let home = data.home
        var html = """
        <div class="plan">
        <h1>Family emergency plan</h1>
        <div class="meta">Printed \(esc(Date.now.formatted(date: .long, time: .omitted))) from Offline Kit. <span class="warn">\(esc(privateWarning))</span></div>
        <div class="boxes">
          <div class="box"><h3>If we’re separated</h3>
            \(row("Meet near home", home.meetingPlace))
            \(row("Meet out of area", plan.meetingOutOfArea))
            \(rowHTML("Out-of-area contact", outOfAreaHTML(data)))
            \(rowHTML("Emergency", emergencyLine))
          </div>
          <div class="box"><h3>Utility shutoffs</h3>
            \(row("Water", plan.waterShutoff))
            \(row("Gas", plan.gasShutoff))
            \(row("Electric", plan.electricShutoff))
            \(row("Notes", plan.shutoffNotes))
            <div class="small">If you turn the gas off, have the gas company or a licensed professional turn it back on.</div>
          </div>
        </div>
        <div class="people">
        """
        for person in data.people {
            let card = data.card(for: person)
            html += """
            <div class="person">
              <h2>\(esc(name(person)))</h2>
              <div class="sub">\(join([card.birthDateText.isEmpty ? "" : "Born " + card.birthDateText,
                                      card.bloodType.isEmpty ? "" : "Blood type " + card.bloodType]))</div>
              \(row("Allergies", card.allergies, strong: true))
              \(row("Conditions", card.conditions))
              \(list("Medicines", card.medications.filter { !$0.name.isBlank }.map(\.line)))
              \(listHTML("Doctors", card.doctors.filter { !$0.isEmpty }.map(contactHTML)))
              \(rowHTML("Pharmacy", card.pharmacy.isEmpty ? "" : contactHTML(card.pharmacy)))
              \(rowHTML("Insurance", insuranceHTML(card.insurance)))
              \(listHTML("Emergency contacts", card.emergencyContacts.filter { !$0.isEmpty }.map(contactHTML)))
            </div>
            """
        }
        if data.people.isEmpty { html += "<p>No people added yet.</p>" }
        html += "</div></div>"
        return html
    }

    // MARK: Binder

    struct BinderOptions {
        var familyPlan = false
        var emergencyInfo = true
        var yourNumbers = true
        var guides = true
        var supplies = true
        /// Offline Kit's own power-out guide (food, generator, water), with its sources.
        var powerOut = true
    }

    /// One printable document: cover, contents, then each section on its own pages.
    @MainActor static func binder(_ data: HouseholdData, options: BinderOptions, library: Library) async -> String {
        var sections: [(title: String, html: String)] = []
        if options.familyPlan { sections.append(("Family emergency plan", planBody(data))) }
        if options.emergencyInfo { sections.append(("Emergency numbers and radio", emergencyBody(data, yourNumbers: options.yourNumbers))) }
        if options.powerOut { sections.append(("Power-out guide: food, generator, water", powerOutBody())) }
        if options.guides {
            for guide in data.extra.savedGuides {
                let book = library.book(guide.ref.bookID)
                let content = dropRepeatedTitle(await guideBody(guide, archive: book?.archive), title: guide.ref.title)
                let source = book?.title ?? guide.bookTitle
                var html = "<h1>\(esc(guide.ref.title))</h1><div class=\"meta\">From \(esc(source))</div>"
                if !guide.notes.isBlank { html += "<div class=\"notes\"><b>Our notes:</b> \(esc(guide.notes))</div>" }
                html += "<div class=\"article\">\(content)</div>"
                sections.append((guide.ref.title, html))
            }
        }
        if options.supplies { sections.append(("Supplies", suppliesBody(data))) }

        let printed = Date.now.formatted(date: .long, time: .omitted)
        var body = """
        <section class="cover">
          <div class="eyebrow">OFFLINE KIT</div>
          <h1 class="cover-title">Household emergency binder</h1>
          <p class="cover-sub">Printed \(esc(printed)). Keep it with your emergency kit, where you can read it with no power and no phone.</p>
          \(options.familyPlan ? "<p class=\"warn\">This binder includes your family plan with private medical details. Store it safely and shred old copies.</p>" : "")
          <p class="cover-sub">Reprint it when your plan, supplies or guides change.</p>
        </section>
        <section class="contents"><h1>Contents</h1><ol>
        """
        body += sections.map { "<li>\(esc($0.title))</li>" }.joined()
        body += "</ol><p class=\"small\">Each section starts on a new page, in this order.</p></section>"
        for (index, section) in sections.enumerated() {
            body += "<section class=\"part\"><div class=\"part-no\">Section \(index + 1) of \(sections.count)</div>\(section.html)</section>"
        }
        return page(title: "Household emergency binder", css: planCSS + binderCSS, body: body, script: options.familyPlan ? fitScript : "")
    }

    static func emergencyBody(_ data: HouseholdData, yourNumbers: Bool) -> String {
        var html = "<h1>Emergency numbers and radio</h1>"
        for group in EmergencyInfo.groups {
            html += "<h2>\(esc(group.title))</h2><p>\(esc(group.intro))</p><table class=\"grid\">"
            for entry in group.entries {
                html += "<tr><td><b>\(esc(entry.title))</b>\(entry.note.isEmpty ? "" : "<div class=\"small\">\(esc(entry.note))</div>")</td><td class=\"num\">\(esc(entry.value))</td></tr>"
            }
            html += "</table>"
        }
        html += "<p class=\"small\">\(esc(EmergencyInfo.radioNote))</p>"
        if yourNumbers && !data.contacts.isEmpty {
            html += "<h2>Our numbers</h2><table class=\"grid\">"
            for contact in data.contacts {
                html += "<tr><td><b>\(esc(contact.name))</b></td><td class=\"num\">\(esc(contact.detail))</td></tr>"
            }
            html += "</table>"
        }
        return html
    }

    /// Every section of the built-in power-out guide, with the official pages each figure came from.
    static func powerOutBody() -> String {
        var html = "<h1>Power-out guide</h1><div class=\"meta\">Food, generator and water safety from \(esc(PowerOutGuide.bookTitle)). Figures checked against the official pages listed under each part on \(esc(SafetySources.checkedOn)).</div>"
        for section in PowerOutGuide.sections {
            html += "<div class=\"guide-part\"><h2>\(esc(section.title))</h2><p>\(esc(section.intro))</p><ul>"
            html += section.points.map { "<li>\(esc($0))</li>" }.joined()
            html += "</ul><div class=\"small sources\"><b>Sources:</b> "
            html += section.sources.map { "\(esc($0.publisher)), “\(esc($0.title))” <span class=\"url\">\(esc($0.url))</span>" }.joined(separator: "; ")
            html += "</div></div>"
        }
        return html
    }

    static func suppliesBody(_ data: HouseholdData) -> String {
        let items = data.extra.supplies
        var html = "<h1>Supplies</h1>"
        if items.isEmpty { return html + "<p>No supplies listed yet.</p>" }
        let attention = items.filter { $0.status() <= .soon }.count
        html += "<p>\(items.count) items as of \(esc(Date.now.formatted(date: .long, time: .omitted))).\(attention > 0 ? " <b>\(attention) expired or expiring within \(SupplyItem.soonDays) days.</b>" : "")</p>"
        for category in SupplyCategory.allCases {
            let group = items.filter { $0.category == category }
                .sorted { ($0.expires ?? .distantFuture, $0.name) < ($1.expires ?? .distantFuture, $1.name) }
            guard !group.isEmpty else { continue }
            // Fixed column widths, so every category's table lines up with the others.
            html += "<h2>\(esc(category.label))</h2><table class=\"grid supplies\"><colgroup><col class=\"c-item\"><col class=\"c-amount\"><col class=\"c-where\"><col class=\"c-expires\"></colgroup><tr><th>Item</th><th>Amount</th><th>Where</th><th>Expires</th></tr>"
            for item in group {
                let flag = switch item.status() {
                case .expired: "<b>EXPIRED</b> "
                case .soon: "<b>SOON</b> "
                default: ""
                }
                let expires = item.expires.map { $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "—"
                html += "<tr><td>\(esc(item.name))\(item.notes.isBlank ? "" : "<div class=\"small\">\(esc(item.notes))</div>")</td><td>\(esc(item.amount))</td><td>\(esc(item.location))</td><td>\(flag)\(esc(expires))</td></tr>"
            }
            html += "</table>"
        }
        return html
    }

    // MARK: Saved guides

    /// The article's readable content with scripts, styles and site chrome removed, and images pointed at the archive.
    static func guideBody(_ guide: SavedGuide, archive: ZimArchive?) async -> String {
        guard let archive else {
            return "<p class=\"warn\">This guide’s archive wasn’t connected when the binder was made, so its text couldn’t be printed.</p>"
        }
        let path = guide.ref.path
        return await Task.detached(priority: .userInitiated) { () -> String in
            guard let content = archive.content(atPath: path),
                  let html = String(data: content.data, encoding: .utf8) ?? String(data: content.data, encoding: .isoLatin1) else {
                return "<p class=\"warn\">This guide couldn’t be found in its archive.</p>"
            }
            let base = ArticleRef(bookID: archive.uuid, path: content.path).url
            return GuideCleaner.clean(html, base: base)
        }.value
    }

    /// The section already shows the guide's title, so a matching first heading in the article is left out.
    private static func dropRepeatedTitle(_ html: String, title: String) -> String {
        guard let range = html.range(of: #"<h1\b[^>]*>[\s\S]*?</h1>"#, options: [.regularExpression, .caseInsensitive]) else { return html }
        let text = html[range].replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.caseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { return html }
        var out = html
        out.removeSubrange(range)
        return out
    }

    // MARK: Pieces

    /// "Emergency 911 · Poison Help 1-800-222-1222", as HTML with numbers kept on one line.
    private static var emergencyLine: String {
        EmergencyInfo.groups.first?.entries.prefix(2).map { "\(esc($0.title)) <span class=\"phone\">\(esc($0.value))</span>" }
            .joined(separator: " · ") ?? ""
    }

    private static func name(_ person: Person) -> String { person.name.isBlank ? "Unnamed" : person.name }

    private static func outOfArea(_ data: HouseholdData) -> String {
        join([data.home.outOfAreaContact, data.extra.plan.outOfAreaPhone])
    }

    private static func meetingText(_ data: HouseholdData) -> String {
        join([data.home.meetingPlace.isBlank ? "" : "Near home: " + data.home.meetingPlace,
              data.extra.plan.meetingOutOfArea.isBlank ? "" : "Out of area: " + data.extra.plan.meetingOutOfArea], separator: "; ")
    }

    /// "Dr. Ana Ruiz (Pediatrician) · 555-0110", as HTML; the phone number never breaks across lines.
    private static func contactHTML(_ c: PhoneContact) -> String {
        [c.label.isBlank ? "" : esc(c.label), c.phone.isBlank ? "" : "<span class=\"phone\">\(esc(c.phone))</span>"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func outOfAreaHTML(_ data: HouseholdData) -> String {
        contactHTML(PhoneContact(name: data.home.outOfAreaContact, phone: data.extra.plan.outOfAreaPhone))
    }

    private static func insuranceHTML(_ i: Insurance) -> String {
        let text = esc(join([i.provider, i.memberID.isBlank ? "" : "member \(i.memberID)", i.groupNumber.isBlank ? "" : "group \(i.groupNumber)"]))
        let phone = i.phone.isBlank ? "" : "<span class=\"phone\">\(esc(i.phone))</span>"
        return [text, phone].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func join(_ parts: [String], separator: String = " · ", html: Bool = false) -> String {
        let kept = parts.filter { !$0.isBlank }
        return html ? kept.map { $0.contains("<b>") ? $0 : esc($0) }.joined(separator: separator)
                    : kept.joined(separator: separator)
    }

    private static func line(_ label: String, _ value: String, strong: Bool = false) -> String {
        guard !value.isBlank else { return "" }
        let text = strong ? "<b>\(esc(value))</b>" : esc(value)
        return "<div class=\"wline\"><span class=\"wl\">\(esc(label)):</span> \(text)</div>"
    }

    private static func lineHTML(_ label: String, _ html: String) -> String {
        guard !html.isBlank else { return "" }
        return "<div class=\"wline\"><span class=\"wl\">\(esc(label)):</span> \(html)</div>"
    }

    private static func contactLine(_ c: PhoneContact, prefix: String? = nil) -> String {
        let label = [prefix, c.label.isBlank ? nil : c.label].compactMap { $0 }.joined(separator: ": ")
        return "<div class=\"wline\">\(esc(label)) <b class=\"phone\">\(esc(c.phone))</b></div>"
    }

    private static func row(_ label: String, _ value: String, strong: Bool = false) -> String {
        guard !value.isBlank else { return "" }
        return "<div class=\"row\"><span class=\"label\">\(esc(label))</span> \(strong ? "<b>\(esc(value))</b>" : esc(value))</div>"
    }

    /// Like `row`, for a value that's already HTML.
    private static func rowHTML(_ label: String, _ html: String) -> String {
        guard !html.isBlank else { return "" }
        return "<div class=\"row\"><span class=\"label\">\(esc(label))</span> \(html)</div>"
    }

    /// Like `list`, for values that are already HTML.
    private static func listHTML(_ label: String, _ values: [String]) -> String {
        guard !values.isEmpty else { return "" }
        if values.count == 1 { return rowHTML(label, values[0]) }
        return "<div class=\"row\"><span class=\"label\">\(esc(label))</span><ul>\(values.map { "<li>\($0)</li>" }.joined())</ul></div>"
    }

    private static func list(_ label: String, _ values: [String]) -> String {
        guard !values.isEmpty else { return "" }
        if values.count == 1 { return row(label, values[0]) }
        return "<div class=\"row\"><span class=\"label\">\(esc(label))</span><ul>\(values.map { "<li>\(esc($0))</li>" }.joined())</ul></div>"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func page(title: String, css: String, body: String, script: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>\(baseCSS)\(css)</style>\(script.isEmpty ? "" : "<script>\(script)</script>")</head>
        <body><div class="page">\(body)</div></body></html>
        """
    }

    // MARK: Styles

    private static let baseCSS = """
    @page { margin: 0.5in; }
    /* WebKit prints a CSS pixel as 0.8 pt on Mac and iPhone (measured), so 90px is one printed inch. */
    :root { --in: 90px; }
    /* Exactly the printable width. iPhone's print formatter scales the widest content to the page, so this keeps 1 in = 1 in. */
    .page { width: calc(7.5 * var(--in)); }
    html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    body { margin: 0; color: #000; background: #fff; font: 10.5pt/1.4 ui-serif, "New York", Georgia, serif; -webkit-text-size-adjust: none; }
    h1, h2, h3, .eyebrow, .wtitle, .label, .meta, .small, th { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; }
    h1 { font-size: 20pt; margin: 0 0 4pt; line-height: 1.15; }
    h2 { font-size: 13pt; margin: 14pt 0 4pt; break-after: avoid; }
    h3 { font-size: 11pt; margin: 0 0 4pt; }
    .warn { font-weight: 600; }
    .small { font-size: 8.5pt; color: #333; }
    .meta { font-size: 9pt; color: #333; margin-bottom: 10pt; }
    a { color: inherit; text-decoration: none; }
    .phone { white-space: nowrap; }
    """

    private static let walletCSS = """
    body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; }
    .sheet-note { font-size: 9pt; margin-bottom: 0.2in; }
    .pair { display: flex; width: calc(6.75 * var(--in)); height: calc(2.125 * var(--in)); border: 0.75pt solid #000; margin: 0 0 calc(0.25 * var(--in)); break-inside: avoid; }
    /* 7.2 pt body text; walletFitScript shrinks a card that's too full, down to 6 pt, and reports any still too full. */
    .wcard { box-sizing: border-box; width: calc(3.375 * var(--in)); height: calc(2.125 * var(--in)); padding: calc(0.09 * var(--in)) calc(0.11 * var(--in)); overflow: hidden; font-size: 7.2pt; line-height: 1.25; }
    .front { border-right: 0.75pt dashed #000; }
    .wtitle { font-size: 0.85em; font-weight: 800; letter-spacing: 0.08em; border-bottom: 0.75pt solid #000; padding-bottom: 1.5pt; margin-bottom: 3pt; }
    .wname { font-size: 1.45em; font-weight: 700; line-height: 1.1; margin-bottom: 1pt; }
    .wline { margin: 0 0 1.4pt; }
    .wl { font-weight: 700; }
    """

    private static let planCSS = """
    .plan { width: calc(7.5 * var(--in)); }
    .boxes { display: flex; gap: calc(0.15 * var(--in)); margin-bottom: calc(0.12 * var(--in)); break-inside: avoid; }
    .box { flex: 1; border: 1pt solid #000; border-radius: 6pt; padding: 7pt 9pt; }
    .row { margin: 1.5pt 0; }
    .row ul { margin: 1pt 0 0 0; padding-left: 14pt; }
    .label { font-weight: 700; font-size: 8.5pt; text-transform: uppercase; letter-spacing: 0.03em; margin-right: 3pt; }
    /* Inline blocks, not a grid: WebKit never splits an inline block across pages, on Mac or iPhone. */
    .people { font-size: 0; }
    .person { display: inline-block; vertical-align: top; box-sizing: border-box; width: calc(50% - 0.06 * var(--in));
              margin: 0 0 calc(0.12 * var(--in)); font-size: 10.5pt; border: 0.75pt solid #000; border-radius: 6pt; padding: 7pt 9pt; }
    .person:nth-child(odd) { margin-right: calc(0.12 * var(--in)); }
    .person h2 { margin: 0; }
    .sub { font-size: 9pt; margin-bottom: 3pt; }
    """

    private static let binderCSS = """
    section { break-before: page; }
    section.cover { break-before: auto; padding-top: 2.4in; }
    .eyebrow { font-size: 10pt; font-weight: 700; letter-spacing: 0.15em; }
    .cover-title { font-size: 34pt; margin: 6pt 0 14pt; }
    .cover-sub { font-size: 13pt; max-width: 5.5in; }
    .contents ol { font-size: 13pt; line-height: 1.7; }
    .part-no { font: 600 8.5pt -apple-system, Helvetica, sans-serif; letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 6pt; }
    .plan { width: auto; }
    .notes { border-left: 2pt solid #000; padding: 2pt 0 2pt 8pt; margin: 0 0 10pt; }
    table.grid { width: 100%; border-collapse: collapse; margin: 4pt 0 8pt; }
    table.grid td, table.grid th { border-bottom: 0.5pt solid #888; padding: 3pt 4pt; vertical-align: top; text-align: left; }
    table.grid tr { break-inside: avoid; }
    td.num { white-space: nowrap; font-weight: 700; text-align: right; }
    table.supplies { table-layout: fixed; }
    table.supplies col.c-item { width: 44%; } table.supplies col.c-amount { width: 16%; }
    table.supplies col.c-where { width: 22%; } table.supplies col.c-expires { width: 18%; }
    .guide-part { break-inside: avoid; }
    .guide-part ul { margin: 2pt 0 4pt; padding-left: 16pt; }
    .guide-part li { margin: 2pt 0; }
    .sources .url { word-break: break-all; }
    th { font-size: 8.5pt; text-transform: uppercase; }
    .article img { max-width: 100%; max-height: 4in; height: auto; break-inside: avoid; }
    .article figure, .article .thumb { margin: 6pt 0; break-inside: avoid; }
    .article table { border-collapse: collapse; font-size: 9pt; max-width: 100%; }
    .article td, .article th { border: 0.5pt solid #999; padding: 2pt 4pt; vertical-align: top; }
    .article pre, .article code { white-space: pre-wrap; font-size: 9pt; }
    .article h1 { font-size: 15pt; } .article h2 { font-size: 13pt; } .article h3 { font-size: 11pt; }
    .article .mw-editsection, .article .navbox, .article .noprint, .article sup.reference,
    .article .mw-jump-link, .article .metadata, .article .catlinks { display: none !important; }
    """

    /// Fits the one-page plan on one Letter page. When it has to shrink, it also widens by the same factor, so the
    /// printed plan still fills the page width (a narrow, zoomed plan left a wide right margin). Finds the largest
    /// zoom that fits by bisection, since a wider plan is also a shorter one.
    private static let fitScript = """
    window.fitToPage = function() {
      var plan = document.querySelector('.plan'); if (!plan) return [];
      // In the binder the plan is one section, with its "Section 1 of 4" line: fit the whole section on its page,
      // so the next section doesn't start after a mostly blank page.
      var box = plan.closest('section') || plan, page = box === plan ? document.querySelector('.page') : null;
      var width = 7.5 * 90, limit = 10 * 90 - (box === plan ? 8 : 40);   // a Letter page inside half-inch margins, in CSS px (90 per inch); the binder's page numbers take a little more
      function heightAt(z) { plan.style.width = (width / z) + 'px'; if (page) page.style.width = (width / z) + 'px'; return box.getBoundingClientRect().height; }
      if (heightAt(1) <= limit) { plan.style.width = ''; if (page) page.style.width = ''; return []; }
      var lo = 0.55, hi = 1;
      for (var i = 0; i < 14; i++) { var mid = (lo + hi) / 2; if (heightAt(mid) * mid <= limit) lo = mid; else hi = mid; }
      heightAt(lo);
      (box === plan ? document.body : box).style.zoom = lo;
      return [];
    };
    """

    /// Shrinks any wallet card whose text doesn't fit, in small steps down to 6 pt. Returns the names of people whose
    /// cards still don't fit, so the app can say so before printing.
    private static let walletFitScript = """
    window.fitToPage = function() {
      var full = [];
      document.querySelectorAll('.wcard').forEach(function(card) {
        var size = 7.2;
        while (card.scrollHeight > card.clientHeight + 1 && size > 6.05) {
          size = Math.round((size - 0.2) * 10) / 10;
          card.style.fontSize = size + 'pt';
        }
        var name = card.getAttribute('data-name') || '';
        if (card.scrollHeight > card.clientHeight + 1 && full.indexOf(name) < 0) full.push(name);
      });
      return full;
    };
    """

    /// What to say before printing cards that are still too full.
    static func tooFullMessage(_ names: [String]) -> String {
        names.map { "Card for \($0) is too full: shorten medicines or contacts." }.joined(separator: "\n")
    }
}

/// Strips an archived web page down to its readable content for printing.
enum GuideCleaner {
    static func clean(_ html: String, base: URL) -> String {
        var s = html
        if let body = s.range(of: #"<body[^>]*>([\s\S]*)</body>"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[body])
            s = s.replacingOccurrences(of: #"^<body[^>]*>|</body>$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let drop = [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<noscript[\s\S]*?</noscript>"#,
                    #"<link[^>]*>"#, #"<meta[^>]*>"#, #"<form[\s\S]*?</form>"#, #"<button[\s\S]*?</button>"#,
                    #"<iframe[\s\S]*?</iframe>"#, #"<input[^>]*>"#, #"<!--[\s\S]*?-->"#,
                    // Site navigation and footers: menus, feeds and links that mean nothing on paper.
                    #"<nav\b[\s\S]*?</nav>"#, #"<footer\b[\s\S]*?</footer>"#, #"<svg\b[\s\S]*?</svg>"#]
        for pattern in drop { s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive]) }
        s = s.replacingOccurrences(of: #"<(video|audio)[\s\S]*?</\1>"#, with: "<p class=\"small\">[Video or audio isn’t included in print.]</p>",
                                   options: [.regularExpression, .caseInsensitive])
        // Collapsed sections print open.
        s = s.replacingOccurrences(of: #"<(/?)details\b[^>]*>"#, with: "<$1div>", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<(/?)summary\b[^>]*>"#, with: "<$1div>", options: [.regularExpression, .caseInsensitive])
        // Inline styles and event handlers can hide content or reach out; neither belongs on paper.
        s = s.replacingOccurrences(of: #"\s(style|on[a-z]+|hidden)\s*=\s*("[^"]*"|'[^']*')"#, with: "", options: [.regularExpression, .caseInsensitive])
        return rewriteImages(s, base: base)
    }

    /// Points every image at the archive (absolute zim:// URL) and loads it now rather than lazily.
    private static func rewriteImages(_ html: String, base: URL) -> String {
        guard let tag = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for match in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let original = ns.substring(with: match.range)
            let src = attribute("data-src", in: original) ?? attribute("src", in: original)
            if let src, let url = resolve(src, base: base) {
                let alt = attribute("alt", in: original) ?? ""
                // Keep the image's own size so icons stay icon-sized; CSS still caps big ones at the page width.
                let size = ["width", "height"].compactMap { name in
                    attribute(name, in: original).flatMap { Int($0.filter(\.isNumber)) }.map { "\(name)=\"\($0)\"" }
                }.joined(separator: " ")
                out += "<img src=\"\(url.absoluteString)\" alt=\"\(PrintDocuments.esc(alt))\" \(size)>"
            }
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for group in [2, 3] where m.range(at: group).location != NSNotFound {
            let value = (tag as NSString).substring(with: m.range(at: group))
            return value.replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    private static func resolve(_ src: String, base: URL) -> URL? {
        let trimmed = src.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("data:") { return URL(string: trimmed) }
        if trimmed.lowercased().hasPrefix("http") { return nil }   // printing never reaches the network
        let url = URL(string: trimmed, relativeTo: base)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: $0, relativeTo: base) }
        guard let absolute = url?.absoluteURL, absolute.scheme == ZimSchemeHandler.scheme else { return nil }
        return absolute
    }
}
