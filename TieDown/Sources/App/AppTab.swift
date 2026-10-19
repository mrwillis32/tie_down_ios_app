import Foundation

/// A native tab (or a "More" entry) that hosts a web section. Paths come from apps/app/src/routes.ts.
struct AppTab: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let path: String

    /// Primary tab-bar entries for a portal. "More" is appended by the tab view.
    static func primary(for portal: Portal) -> [AppTab] {
        switch portal {
        case .staff:
            [
                AppTab(id: "home", title: "Home", systemImage: "house", path: "/"),
                AppTab(id: "pos", title: "POS", systemImage: "creditcard", path: "/pos"),
                AppTab(id: "reservations", title: "Reservations", systemImage: "calendar", path: "/reservations"),
                AppTab(id: "customers", title: "Customers", systemImage: "person.2", path: "/customers"),
            ]
        case .customer:
            [
                AppTab(id: "home", title: "Home", systemImage: "house", path: "/portal/dashboard"),
                AppTab(id: "reservations", title: "Reservations", systemImage: "calendar", path: "/portal/my-reservations"),
                AppTab(id: "rentals", title: "Rentals", systemImage: "car", path: "/portal/rentals"),
                AppTab(id: "payments", title: "Payments", systemImage: "creditcard", path: "/portal/payment-methods"),
            ]
        case .owner:
            [
                AppTab(id: "home", title: "Home", systemImage: "house", path: "/owners"),
                AppTab(id: "reservations", title: "Reservations", systemImage: "calendar", path: "/owners/reservations"),
                AppTab(id: "statements", title: "Statements", systemImage: "doc.text", path: "/owners/statements"),
                AppTab(id: "billing", title: "Billing", systemImage: "dollarsign.circle", path: "/owners/billing"),
            ]
        }
    }

    /// Secondary sections listed under "More".
    static func more(for portal: Portal) -> [AppTab] {
        switch portal {
        case .staff:
            [
                AppTab(id: "orders", title: "Orders", systemImage: "list.bullet.rectangle", path: "/pos/orders"),
                AppTab(id: "invoices", title: "Invoices", systemImage: "doc.plaintext", path: "/pos/invoices"),
                AppTab(id: "products", title: "Products", systemImage: "shippingbox", path: "/pos/product-setup"),
                AppTab(id: "fleet", title: "Fleet", systemImage: "truck.box", path: "/fleet"),
                AppTab(id: "reports", title: "Reports", systemImage: "chart.bar", path: "/reports"),
                AppTab(id: "team", title: "Team", systemImage: "person.3", path: "/team"),
                AppTab(id: "settings", title: "Web Settings", systemImage: "gearshape", path: "/settings"),
                AppTab(id: "profile", title: "Profile", systemImage: "person.crop.circle", path: "/profile"),
            ]
        case .customer:
            [
                AppTab(id: "vehicle-rentals", title: "Vehicle Rentals", systemImage: "car.2", path: "/portal/vehicle-rentals"),
                AppTab(id: "history", title: "Rental History", systemImage: "clock.arrow.circlepath", path: "/portal/rental-history"),
                AppTab(id: "household", title: "Household", systemImage: "house.and.flag", path: "/portal/household"),
                AppTab(id: "profile", title: "Profile", systemImage: "person.crop.circle", path: "/portal/profile"),
            ]
        case .owner:
            [
                AppTab(id: "analytics", title: "Analytics", systemImage: "chart.line.uptrend.xyaxis", path: "/owners/analytics"),
                AppTab(id: "calendar", title: "Calendar", systemImage: "calendar.badge.clock", path: "/owners/calendar"),
                AppTab(id: "invoices", title: "Invoices", systemImage: "doc.plaintext", path: "/owners/invoices"),
                AppTab(id: "vehicles", title: "Vehicles", systemImage: "car", path: "/owners/vehicle-management"),
                AppTab(id: "profile", title: "Profile", systemImage: "person.crop.circle", path: "/owners/profile"),
            ]
        }
    }
}
