#if canImport(UIKit)
  import Foundation
  import UIKit

  @MainActor
  enum WtsExperiencePresenter {
    private static weak var currentController: UIViewController?

    static func present(
      _ experience: WtsExperience,
      onImpression: @escaping @Sendable () -> Void,
      onAction: @escaping @Sendable (WtsExperienceAction) -> Void,
      onDismiss: @escaping @Sendable (WtsExperienceDismissReason) -> Void
    ) async -> Bool {
      guard let presenter = topViewController(), presenter.presentedViewController == nil else {
        return false
      }
      let controller = ExperienceViewController(
        experience: experience,
        onImpression: onImpression,
        onAction: onAction,
        onDismiss: onDismiss
      )
      if experience.placement == .bottomSheet {
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        controller.sheetPresentationController?.prefersGrabberVisible = true
      } else {
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle =
          UIAccessibility.isReduceMotionEnabled ? .crossDissolve : .coverVertical
      }
      presenter.present(controller, animated: true)
      currentController = controller
      return true
    }

    static func dismissCurrent(
      notify: Bool = true,
      reason: WtsExperienceDismissReason = .dismissed
    ) {
      (currentController as? ExperienceViewController)?.finish(notify: notify, reason: reason)
    }

    private static func topViewController() -> UIViewController? {
      let root = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)?
        .rootViewController
      var current = root
      while let presented = current?.presentedViewController { current = presented }
      if let navigation = current as? UINavigationController {
        return navigation.visibleViewController
      }
      if let tabs = current as? UITabBarController { return tabs.selectedViewController }
      return current
    }
  }

  @MainActor
  private final class ExperienceViewController: UIViewController {
    private let experience: WtsExperience
    private let onImpression: @Sendable () -> Void
    private let onAction: @Sendable (WtsExperienceAction) -> Void
    private let onDismiss: @Sendable (WtsExperienceDismissReason) -> Void
    private var impressionTask: Task<Void, Never>?
    private var autoCloseTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private weak var experienceCard: UIView?
    private var completed = false

    init(
      experience: WtsExperience,
      onImpression: @escaping @Sendable () -> Void,
      onAction: @escaping @Sendable (WtsExperienceAction) -> Void,
      onDismiss: @escaping @Sendable (WtsExperienceDismissReason) -> Void
    ) {
      self.experience = experience
      self.onImpression = onImpression
      self.onAction = onAction
      self.onDismiss = onDismiss
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor =
        experience.placement == .modal
        ? UIColor.black.withAlphaComponent(0.5)
        : .systemBackground

      let card = UIView()
      card.backgroundColor =
        experience.content.themePreset == "dark"
        ? UIColor(red: 0.03, green: 0.07, blue: 0.13, alpha: 1)
        : .systemBackground
      card.layer.cornerRadius = 20
      card.layer.masksToBounds = true
      card.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(card)
      experienceCard = card

      let translation = localizedContent()
      let title = UILabel()
      title.font = .preferredFont(forTextStyle: .title2)
      title.numberOfLines = 0
      title.text = translation.title
      title.accessibilityTraits = .header
      let body = UILabel()
      body.font = .preferredFont(forTextStyle: .body)
      body.numberOfLines = 0
      body.text = translation.description
      let stack = UIStackView()
      stack.axis = .vertical
      stack.spacing = 14
      stack.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(stack)
      if let assetURL = experience.assetURL {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.isHidden = true
        imageView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        imageView.accessibilityElementsHidden = true
        stack.addArrangedSubview(imageView)
        imageTask = Task { [weak imageView] in
          guard
            assetURL.scheme?.lowercased() == "https",
            let (data, response) = try? await URLSession.shared.data(from: assetURL),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            data.count <= 2 * 1_024 * 1_024,
            let image = UIImage(data: data)
          else { return }
          guard !Task.isCancelled else { return }
          imageView?.image = image
          imageView?.isHidden = false
        }
      }
      stack.addArrangedSubview(title)
      stack.addArrangedSubview(body)

      for action in [translation.primaryAction, translation.secondaryAction].compactMap({ $0 }) {
        let button = UIButton(type: .system)
        var configuration =
          action.id == translation.primaryAction?.id
          ? UIButton.Configuration.filled()
          : UIButton.Configuration.tinted()
        configuration.title = action.label
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
        stack.addArrangedSubview(button)
      }
      if experience.content.closeable {
        let close = UIButton(type: .close)
        close.accessibilityLabel = NSLocalizedString("Close", comment: "")
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(UIAction { [weak self] _ in self?.finish(reason: .dismissed) }, for: .touchUpInside)
        card.addSubview(close)
        NSLayoutConstraint.activate([
          close.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
          close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
      }
      let width = card.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
      width.priority = .required
      NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
        card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        experience.placement == .modal
          ? card.centerYAnchor.constraint(equalTo: view.centerYAnchor)
          : card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        width,
        stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 32),
        stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
        stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
      ])
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      impressionTask = Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled, isAtLeastHalfVisible else { return }
        onImpression()
      }
      if let autoCloseSeconds = experience.content.autoCloseSeconds {
        autoCloseTask = Task {
          try? await Task.sleep(
            nanoseconds: UInt64(autoCloseSeconds * 1_000_000_000)
          )
          guard !Task.isCancelled else { return }
          finish(reason: .autoClosed)
        }
      }
    }

    private func localizedContent() -> WtsExperienceLocalizedContent {
      let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
      return experience.content.translations[locale]
        ?? experience.content.translations[String(locale.prefix(2))]
        ?? experience.content.translations.values.first!
    }

    private func perform(_ action: WtsExperienceAction) {
      onAction(action)
      finish(reason: .dismissed)
    }

    private var isAtLeastHalfVisible: Bool {
      guard
        let card = experienceCard,
        let window = card.window,
        !card.isHidden,
        card.alpha > 0
      else { return false }
      let frame = card.convert(card.bounds, to: window)
      let visible = frame.intersection(window.bounds)
      let totalArea = frame.width * frame.height
      return totalArea > 0 && visible.width * visible.height / totalArea >= 0.5
    }

    fileprivate func finish(
      notify: Bool = true,
      reason: WtsExperienceDismissReason = .dismissed
    ) {
      guard !completed else { return }
      completed = true
      impressionTask?.cancel()
      autoCloseTask?.cancel()
      imageTask?.cancel()
      if notify {
        dismiss(animated: true) { [onDismiss] in onDismiss(reason) }
      } else {
        dismiss(animated: true)
      }
    }

    override func viewDidDisappear(_ animated: Bool) {
      super.viewDidDisappear(animated)
      guard !completed else { return }
      completed = true
      impressionTask?.cancel()
      autoCloseTask?.cancel()
      imageTask?.cancel()
      onDismiss(.dismissed)
    }
  }
#endif
