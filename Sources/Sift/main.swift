import Foundation
import SiftCLI

@main
struct SiftCommand {
    static func main() {
        Foundation.exit(SiftCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
