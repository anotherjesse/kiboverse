import SwiftUI
import UIKit

/// Principal class of the KiboShare extension (see `NSExtensionPrincipalClass`
/// in project.yml). A thin UIKit shell: it resolves the app-group seams once,
/// hands them to the intake model, and hosts the SwiftUI card. All policy
/// lives in `ShareIntakeModel`; the extension context appears only here.
final class ShareViewController: UIViewController {
    private var model: ShareIntakeModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        let model = ShareIntakeModel(
            inputItems: items,
            spool: .appGroupWriter(),
            cache: DestinationCacheStore.appGroup()?.load(),
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        )
        self.model = model

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
