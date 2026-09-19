import WidgetKit

/// Reçoit le token que WidgetKit attribue au widget et le dépose chez Milō.
///
/// Le push widget ne transporte aucune donnée — seulement `content-changed` —
/// donc recevoir ce token ne change rien à ce que le widget affiche : il
/// continue d'aller chercher l'état sur le LAN. Ce que ça change, c'est *quand*
/// il y va.
///
/// Le push reste budgété par Apple à la journée et livré de façon opportuniste :
/// il s'ajoute aux timelines, il ne les remplace pas. `MiloTimelineProvider`
/// garde donc sa politique de repli — Milō ne notifie que les changements
/// affichables (source, titre, artiste, état de lecture), et surtout pas le
/// volume, qui bougerait bien trop souvent pour ce budget.
@available(iOS 26.0, *)
struct MiloWidgetPushHandler: WidgetPushHandler {

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = pushInfo.token

        // Plus aucun widget posé : le token ne mènerait nulle part. On le retire
        // plutôt que de laisser Milō pousser vers un écran qui n'existe plus.
        guard !widgets.isEmpty else {
            Task { await MiloAPIClient.unregisterPushToken(token) }
            return
        }

        Task { await MiloAPIClient.registerPushToken(token, kind: .widget) }
    }
}
