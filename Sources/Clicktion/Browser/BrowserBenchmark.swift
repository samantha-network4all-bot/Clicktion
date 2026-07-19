import Foundation

/// One graded task result.
struct BenchResult: Identifiable {
    let id = UUID()
    let name: String
    let passed: Bool
    let answer: String
}

/// A benchmark task: an instruction plus the keywords its answer must contain.
/// `expected` is a list of groups; the answer passes when it contains at least
/// one keyword from every group (AND across groups, OR within a group).
struct BenchmarkTask {
    let name: String
    let instruction: String
    let expected: [[String]]

    func grade(_ answer: String) -> Bool {
        let a = answer.lowercased()
        return expected.allSatisfy { group in
            group.contains { a.contains($0.lowercased()) }
        }
    }
}

/// Ten browser-agent use-cases on stable, server-rendered sites with
/// checkable answers — a comparable benchmark of a model's agent ability.
enum BrowserBenchmark {
    static let tasks: [BenchmarkTask] = [
        BenchmarkTask(
            name: "Link text",
            instruction: "Go to https://example.com and report the exact text of the link on the page.",
            expected: [["more information", "learn more"]]),
        BenchmarkTask(
            name: "Count first page",
            instruction: "Go to https://books.toscrape.com and report exactly how many books are listed on the first page.",
            expected: [["20"]]),
        BenchmarkTask(
            name: "Category count",
            instruction: "On https://books.toscrape.com open the Travel category and report exactly how many books it contains.",
            expected: [["11"]]),
        BenchmarkTask(
            name: "Book price",
            instruction: "On https://books.toscrape.com report the price of the book 'A Light in the Attic'.",
            expected: [["51.77"]]),
        BenchmarkTask(
            name: "Product detail",
            instruction: "On https://books.toscrape.com open the Travel category, open 'Vagabonding', and report its price and how many are in stock.",
            expected: [["36.94"], ["8"]]),
        BenchmarkTask(
            name: "Pagination",
            instruction: "Go to https://books.toscrape.com, then go to page 2 of the catalogue and report the title of the first book listed on page 2.",
            expected: [["in her wake"]]),
        BenchmarkTask(
            name: "Quote author",
            instruction: "Go to https://quotes.toscrape.com and report the author of the first quote.",
            expected: [["einstein"]]),
        BenchmarkTask(
            name: "Quote tag",
            instruction: "Go to https://quotes.toscrape.com and report one tag shown under the first quote.",
            expected: [["change", "deep-thoughts", "thinking", "world"]]),
        BenchmarkTask(
            name: "Search: birth year",
            instruction: "Go to https://en.wikipedia.org, search for 'Ada Lovelace', open her article, and report the year she was born.",
            expected: [["1815"]]),
        BenchmarkTask(
            name: "Search: measurement",
            instruction: "Go to https://en.wikipedia.org, search for 'Mount Everest', open the article, and report its height in metres.",
            expected: [["8,84", "8848", "8849"]]),
    ]
}
