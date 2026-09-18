import UIKit
import WebKit

class ViewController: UIViewController, WKNavigationDelegate {

    var webView: WKWebView!
    var errorView: UIView!
    var reconnectingOverlay: UIView!
    var logoImageView: UIImageView!
    var titleLabel: UILabel!
    var messageLabel: UILabel!

    var connectivityTimer: Timer?
    var initialErrorTimer: Timer?
    var isConnected = false {
        didSet {
            guard isConnected != oldValue else { return }
            scheduleConnectivityCheck()
        }
    }

    /// Vrai dès qu'une première navigation a abouti ou échoué. Sert à reconnaître
    /// le lancement à froid, pendant lequel UIKit émet `sceneDidEnterBackground`
    /// puis `sceneWillEnterForeground` alors que `viewDidLoad` vient déjà de
    /// lancer le chargement.
    private(set) var hasCompletedFirstLoad = false

    /// Date du passage en arrière-plan, pour juger si la page mérite un rechargement
    private var backgroundedAt: Date?

    /// Cadence du sondage de `milo.local` : espacée quand tout va bien, serrée
    /// quand on attend le retour de Milō.
    private let connectedPollInterval: TimeInterval = 15
    private let disconnectedPollInterval: TimeInterval = 3

    /// En deçà de ce temps passé en arrière-plan, la page est réputée encore valide :
    /// la recharger perdrait l'état de la SPA (scroll, vue courante) et
    /// retéléchargerait une vingtaine de sous-ressources pour rien.
    private let reloadAfterBackgroundInterval: TimeInterval = 30

    /// L'adresse de Milō ne bouge qu'au renouvellement du bail DHCP : inutile de
    /// relancer une résolution à chaque sondage.
    private static let ipResolutionInterval: TimeInterval = 300

    override func loadView() {
        let containerView = UIView()
        containerView.backgroundColor = UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0)
        self.view = containerView

        // WebView - CHANGEMENTS ICI pour éviter le flickering
        webView = WKWebView()
        webView.navigationDelegate = self
        webView.backgroundColor = UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0) // ← Changé
        webView.isOpaque = true // ← Changé
        webView.scrollView.backgroundColor = UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0) // ← Changé
        webView.alpha = 0.0
        containerView.addSubview(webView)
        
        setupErrorView()
        setupReconnectingOverlay()
    }
    
    func setupErrorView() {
        // Vue d'erreur - VISIBLE au démarrage (on la masquera si connexion OK)
        errorView = UIView()
        errorView.backgroundColor = UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0)
        errorView.alpha = 0.0 // Invisible mais pas hidden
        errorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorView)
        
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stackView)
        
        // Logo
        logoImageView = UIImageView(image: UIImage(named: "Logo"))
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(logoImageView)
        
        // Spacer 64px
        let spacer64 = UIView()
        stackView.addArrangedSubview(spacer64)
        
        // Titre
        titleLabel = UILabel()
        titleLabel.text = "Milo n'est pas disponible"
        titleLabel.textAlignment = .center
        titleLabel.font = UIFont(name: "NeueMontreal-Medium", size: 18) ?? .systemFont(ofSize: 18, weight: .medium)
        titleLabel.textColor = UIColor(red: 0x76/255.0, green: 0x7C/255.0, blue: 0x76/255.0, alpha: 1.0)
        stackView.addArrangedSubview(titleLabel)
        
        // Spacer 8px
        let spacer8 = UIView()
        stackView.addArrangedSubview(spacer8)
        
        // Message
        messageLabel = UILabel()
        messageLabel.text = "Assurez-vous d'être connecté sur le même réseau local."
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.font = UIFont(name: "NeueMontreal-Medium", size: 16) ?? .systemFont(ofSize: 16, weight: .medium)
        messageLabel.textColor = UIColor(red: 0xA6/255.0, green: 0xAC/255.0, blue: 0xA6/255.0, alpha: 1.0)
        stackView.addArrangedSubview(messageLabel)
        
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            stackView.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: errorView.trailingAnchor, constant: -40),
            
            logoImageView.widthAnchor.constraint(equalToConstant: 86),
            logoImageView.heightAnchor.constraint(equalToConstant: 48),
            spacer64.heightAnchor.constraint(equalToConstant: 64),
            spacer8.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    func setupReconnectingOverlay() {
        reconnectingOverlay = UIView()
        reconnectingOverlay.backgroundColor = UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0)
        reconnectingOverlay.alpha = 0.0
        reconnectingOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reconnectingOverlay)

        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        reconnectingOverlay.addSubview(logo)

        NSLayoutConstraint.activate([
            reconnectingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            reconnectingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reconnectingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reconnectingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            logo.centerXAnchor.constraint(equalTo: reconnectingOverlay.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: reconnectingOverlay.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 86),
            logo.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    func showReconnectingOverlay() {
        reconnectingOverlay.alpha = 1.0
    }

    func hideReconnectingOverlay() {
        UIView.animate(withDuration: 0.3) {
            self.reconnectingOverlay.alpha = 0.0
        }
    }

    func handleReturnFromBackground() {
        // Lancement à froid : UIKit émet `sceneDidEnterBackground` puis
        // `sceneWillEnterForeground` dans la foulée de `viewDidLoad`. Recharger ici
        // lancerait une seconde navigation qui annulerait la première.
        guard hasCompletedFirstLoad else { return }

        let awayFor = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        backgroundedAt = nil

        // Absence courte et page toujours affichée : la recharger ferait repartir
        // la SPA de zéro sans rien apprendre de neuf.
        if isConnected && awayFor < reloadAfterBackgroundInterval {
            hideReconnectingOverlay()
            return
        }

        tryConnectToMilo()
    }

    func enterBackground() {
        backgroundedAt = Date()
        showReconnectingOverlay()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.customUserAgent = "Milo-iOS-App/1.0"
        
        // Essayer de se connecter immédiatement
        tryConnectToMilo()
        
        // Afficher le message d'erreur après 2.5 secondes si pas connecté
        initialErrorTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            if self?.isConnected != true {
                // Afficher la vue d'erreur avec animation
                UIView.animate(withDuration: 0.3) {
                    self?.errorView.alpha = 1.0
                }
            }
        }
        
        // Démarrer le monitoring
        scheduleConnectivityCheck()
    }
    
    func tryConnectToMilo() {
        let url = URL(string: "http://milo.local")!
        webView.load(URLRequest(url: url))
    }
    
    /// (Re)programme le sondage de `milo.local` à la cadence de l'état courant.
    func scheduleConnectivityCheck() {
        let interval = isConnected ? connectedPollInterval : disconnectedPollInterval
        guard connectivityTimer?.timeInterval != interval else { return }

        connectivityTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkMiloAndConnect()
        }
        // `.common` : en mode `.default`, le sondage s'interrompt tant que
        // l'utilisateur scrolle la webview.
        RunLoop.main.add(timer, forMode: .common)
        connectivityTimer = timer
    }
    
    func checkMiloAndConnect() {
        guard let url = URL(string: "http://milo.local") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2.0
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let isAvailable = error == nil && (response as? HTTPURLResponse)?.statusCode == 200

            // Hors du thread principal : `getaddrinfo` bloque le temps de la résolution.
            if isAvailable { Self.cacheResolvedIPAddress() }

            DispatchQueue.main.async {
                guard let self = self else { return }

                if isAvailable && !self.isConnected {
                    // Milō répond sans que sa page soit affichée → (re)charger, sauf si
                    // une navigation est déjà en vol : la relancer l'annulerait et
                    // ferait repartir le chargement à chaque sondage.
                    if !self.webView.isLoading { self.tryConnectToMilo() }
                } else if !isAvailable && self.isConnected {
                    // milo.local pas disponible mais on était connecté → afficher erreur
                    self.isConnected = false
                    self.showErrorView()
                }
            }
        }.resume()
    }
    
    /// Résout `milo.local` et mémorise l'adresse pour le widget.
    ///
    /// `URLSession` ne réécrit pas l'URL de la réponse avec l'adresse résolue :
    /// `httpResponse.url?.host` valait toujours « milo.local », si bien que la clé
    /// partagée restait vide et que l'extension WidgetKit refaisait une résolution
    /// mDNS à chaque réveil — lente, et fragile dans son budget d'exécution.
    ///
    /// Bloquant : à n'appeler que hors du thread principal.
    private static func cacheResolvedIPAddress() {
        guard let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID) else { return }

        let hasCachedIP = defaults.string(forKey: MiloAPIClient.ipAddressKey)?.isEmpty == false
        let resolvedAt = defaults.object(forKey: MiloAPIClient.ipResolvedAtKey) as? Double ?? 0
        if hasCachedIP, Date().timeIntervalSince1970 - resolvedAt < ipResolutionInterval { return }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("milo.local", nil, &hints, &info) == 0, let first = info else { return }
        defer { freeaddrinfo(info) }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr,
                          first.pointee.ai_addrlen,
                          &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return }

        let ip = String(cString: buffer)
        guard !ip.isEmpty else { return }

        defaults.set(ip, forKey: MiloAPIClient.ipAddressKey)
        defaults.set(Date().timeIntervalSince1970, forKey: MiloAPIClient.ipResolvedAtKey)
    }

    func showErrorView() {
        // Afficher la vue d'erreur avec animation
        UIView.animate(withDuration: 0.3) {
            self.errorView.alpha = 1.0
            self.webView.alpha = 0.0
        }
    }
    
    func hideErrorView() {
        // Masquer la vue d'erreur et afficher la webview
        UIView.animate(withDuration: 0.3) {
            self.errorView.alpha = 0.0
            self.webView.alpha = 1.0
        }
    }

    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasCompletedFirstLoad = true
        isConnected = true

        // Annuler le timer d'erreur initial (connexion réussie)
        initialErrorTimer?.invalidate()

        // Ajouter classe CSS
        webView.evaluateJavaScript("document.body.classList.add('ios-app');", completionHandler: nil)

        // Synchroniser les settings volume (step + limites) depuis Milo
        Task { await MiloAPIClient.syncVolumeSettings() }

        // Masquer l'erreur et afficher la webview
        hideErrorView()
        hideReconnectingOverlay()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Navigation remplacée par une autre : ce n'est pas un échec de Milō, et la
        // traiter comme tel ferait clignoter l'écran d'erreur.
        if (error as NSError).code == NSURLErrorCancelled { return }

        hasCompletedFirstLoad = true

        // Sans cette remise à zéro, `checkMiloAndConnect` ne retentait jamais après
        // un échec survenu alors qu'on était connecté : sa condition de reconnexion
        // exige `!isConnected`, et l'app restait sur l'écran d'erreur bien que Milō
        // réponde.
        isConnected = false

        // Connexion échouée - masquer l'overlay de reconnexion et afficher l'erreur
        hideReconnectingOverlay()
        showErrorView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView.frame = view.bounds
    }
    
    deinit {
        connectivityTimer?.invalidate()
        initialErrorTimer?.invalidate()
    }
}
