import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI

class BookmarkEditTitleViewController: ThemedHostingController<AnyView> {
    private let viewModel: any BookmarkEditing
    let onDismiss: ((String, Bool) -> Void)?
    var editSaved: Bool = false

    /// Set at init rather than afterwards: generating a title starts as soon as the view model
    /// is built, so a source assigned later would miss the events that generation reports
    let source: BookmarkAnalyticsSource

    init(manager: BookmarkManager,
         bookmark: Bookmark,
         state: BookmarkEditViewModel.EditState,
         style: BookmarkEditTheme.Style = .player,
         source: BookmarkAnalyticsSource = .unknown,
         onDismiss: ((String, Bool) -> Void)? = nil) {
        let episode = manager.episode(for: bookmark)
        self.source = source

        let viewModel: any BookmarkEditing
        let rootView: AnyView

        if FeatureFlag.smartBookmarks.enabled {
            let theme = BookmarkEditTheme(episode: episode, style: style)
            let smartViewModel = BookmarkEditViewModel(manager: manager, bookmark: bookmark, state: state, source: source)
            viewModel = smartViewModel
            rootView = AnyView(BookmarkEditView(viewModel: smartViewModel, theme: theme))
        } else {
            let theme = BookmarkEditTheme(episode: episode)
            let titleViewModel = BookmarkEditTitleViewModel(manager: manager, bookmark: bookmark, state: .init(state))
            viewModel = titleViewModel
            rootView = AnyView(BookmarkEditTitleView(viewModel: titleViewModel, theme: theme))
        }

        self.viewModel = viewModel
        self.onDismiss = onDismiss

        super.init(rootView: rootView)

        viewModel.router = self
        viewModel.analyticsSource = source
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        track(.bookmarkEditFormShown, stage: .shown)
        viewModel.viewDidAppear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !editSaved {
            track(.bookmarkEditFormDismissed, stage: .dismissed)
        }
    }

    private func track(_ event: AnalyticsEvent, stage: BookmarkEditStage) {
        var properties = viewModel.analyticsProperties(for: stage)
        properties["source"] = source.rawValue

        Analytics.track(event, properties: properties)
    }

    @MainActor dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension BookmarkEditTitleViewController: BookmarkEditRouter {
    func dismiss() {
        dismiss(animated: true)
        onDismiss?(viewModel.originalTitle, true)
    }

    func titleUpdated(title: String) {
        editSaved = true
        track(.bookmarkEditFormSubmitted, stage: .submitted)
        dismiss(animated: true)
        onDismiss?(title, false)
    }
}
