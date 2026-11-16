import SwiftUI

// Route CLI before constructing the SwiftUI app/delegate. The restore helper is a separate binary.
CommandRouting.runIfNeeded()
MacStrechedScreenApp.main()
