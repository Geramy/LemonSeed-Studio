public import SwiftUI
import GitKit

/// The branch popover of the Source Control panel: `BranchManagerView`
/// with a title, closing after a switch or a new branch.
public struct BranchPickerView: View {
    @Bindable var model: SourceControlModel
    var dismiss: () -> Void
    var onCreatePullRequest: (() -> Void)?

    public init(model: SourceControlModel, dismiss: @escaping () -> Void = {}, onCreatePullRequest: (() -> Void)? = nil) {
        self.model = model
        self.dismiss = dismiss
        self.onCreatePullRequest = onCreatePullRequest
    }

    public var body: some View {
        NavigationStack {
            BranchManagerView(model: model, onFinished: dismiss, onCreatePullRequest: onCreatePullRequest.map { action in
                { dismiss(); action() }
            })
            .navigationTitle("Branches")
            .inlineTitle()
        }
    }
}
