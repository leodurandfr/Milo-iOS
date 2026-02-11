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
    var isConnected = false

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
        tryConnectToMilo()
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
        startConnectivityCheck()
    }
    
    func tryConnectToMilo() {
        let url = URL(string: "http://milo.local")!
        webView.load(URLRequest(url: url))
    }
    
    func startConnectivityCheck() {
        // Timer pour vérifier milo.local toutes les 4 secondes
        connectivityTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.checkMiloAndConnect()
        }
    }
    
    func checkMiloAndConnect() {
        guard let url = URL(string: "http://milo.local") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2.0
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            // Store resolved IP for the widget
            if let httpResponse = response as? HTTPURLResponse,
               let responseURL = httpResponse.url,
               let host = responseURL.host,
               host != "milo.local" {
                UserDefaults(suiteName: "group.leodurand.Milo-iOS")?.set(host, forKey: "milo_ip_address")
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                let isAvailable = error == nil && (response as? HTTPURLResponse)?.statusCode == 200

                if isAvailable && !self.isConnected {
                    // milo.local disponible et on n'est pas connecté → se connecter
                    self.tryConnectToMilo()
                } else if !isAvailable && self.isConnected {
                    // milo.local pas disponible mais on était connecté → afficher erreur
                    self.isConnected = false
                    self.showErrorView()
                }
            }
        }.resume()
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
        isConnected = true

        // Annuler le timer d'erreur initial (connexion réussie)
        initialErrorTimer?.invalidate()

        // Ajouter classe CSS
        webView.evaluateJavaScript("document.body.classList.add('ios-app');", completionHandler: nil)

        // Synchroniser le step volume depuis les settings Milo
        Task { await MiloAPIClient.syncVolumeStep() }

        // Masquer l'erreur et afficher la webview
        hideErrorView()
        hideReconnectingOverlay()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
