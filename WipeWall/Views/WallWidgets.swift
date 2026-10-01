import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Drop-in host for all user-added widgets. Place this in the Wall ZStack and
/// pass the canvas' global edit state; outside edit mode it has no blank-area
/// hit target, so the drawing canvas and the original modules stay responsive.
struct WallWidgetCanvas: View {
    @ObservedObject var store: WallWidgetStore
    @ObservedObject var layers: WallLayerStore
    @ObservedObject var dashboard: DashboardModel
    @ObservedObject var voice: DonVoiceController
    @Binding var isEditing: Bool
    let containerSize: CGSize
    let onRequestEdit: (UUID) -> Void
    var onInteractionChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Group {
            ForEach(store.items) { item in
                WallWidgetElement(
                    item: item,
                    store: store,
                    layers: layers,
                    dashboard: dashboard,
                    voice: voice,
                    isEditing: $isEditing,
                    containerSize: containerSize,
                    onRequestEdit: { onRequestEdit(item.id) },
                    onInteractionChanged: onInteractionChanged
                )
            }

            if isEditing,
               let selectedID = store.selectedID,
               let item = store.items.first(where: { $0.id == selectedID }) {
                WallWidgetEditControls(
                    item: item,
                    store: store,
                    layers: layers,
                    containerSize: containerSize
                )
                .zIndex(75_000)
            }
        }
    }
}

/// Editing controls stay in canvas coordinates instead of inheriting the
/// widget's scale and rotation. This keeps every target visible and tappable,
/// including when a widget is tiny, rotated, or parked against an edge.
struct WallWidgetEditControls: View {
    let item: WallWidgetItem
    @ObservedObject var store: WallWidgetStore
    @ObservedObject var layers: WallLayerStore
    let containerSize: CGSize

    var body: some View {
        HStack(spacing: 2) {
            control(
                symbol: "trash",
                label: "Delete \(item.kind.title) widget",
                identifier: "wall.widget.\(item.kind.rawValue).delete"
            ) {
                store.remove(item.id)
            }
            depthControl(
                .back,
                label: "Send all the way to back",
                identifier: "wall.widget.\(item.kind.rawValue).back"
            ) {
                layers.sendToBack(.widget(item.id))
            }
            depthControl(
                .front,
                label: "Bring all the way to front",
                identifier: "wall.widget.\(item.kind.rawValue).forward"
            ) {
                layers.bringToFront(.widget(item.id))
            }
            control(
                symbol: "rotate.right",
                label: "Snap rotation",
                identifier: "wall.widget.\(item.kind.rawValue).snap"
            ) {
                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.82)) {
                    store.snapRotation(item.id)
                }
            }
        }
        .padding(3)
        .background(Color.white)
        .overlay(Capsule().stroke(Color.black, lineWidth: 1))
        .clipShape(Capsule())
        .position(controlBarPosition)
    }

    private func depthControl(
        _ placement: WallLayerDepthPlacement,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            layers.noteControlInteraction()
            action()
        } label: {
            WallLayerDepthIcon(placement: placement)
                .frame(width: 29, height: 29)
                .background(Color.black)
                .clipShape(Circle())
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(WallWidgetPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func control(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            layers.noteControlInteraction()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 29, height: 29)
                .background(Color.black)
                .clipShape(Circle())
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(WallWidgetPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var controlBarPosition: CGPoint {
        let center = item.center(in: containerSize)
        let width = item.kind.baseSize.width * CGFloat(item.scale)
        let height = item.kind.baseSize.height * CGFloat(item.scale)
        let radians = CGFloat(item.rotationDegrees * .pi / 180)
        let boundingHalfHeight = abs(width * sin(radians)) / 2
            + abs(height * cos(radians)) / 2
        let halfToolbarWidth: CGFloat = 86
        let halfToolbarHeight: CGFloat = 25
        let above = center.y - boundingHalfHeight - halfToolbarHeight
        let below = center.y + boundingHalfHeight + halfToolbarHeight
        let y = above >= halfToolbarHeight
            ? above
            : min(max(below, halfToolbarHeight), max(halfToolbarHeight, containerSize.height - halfToolbarHeight))
        return CGPoint(
            x: min(
                max(center.x, halfToolbarWidth),
                max(halfToolbarWidth, containerSize.width - halfToolbarWidth)
            ),
            y: y
        )
    }
}

/// The sheet opened by the edit-mode + button. Every catalog item can be added
/// once, keeping the canvas intentional instead of generating empty modules.
struct WallWidgetPicker: View {
    @ObservedObject var store: WallWidgetStore
    @ObservedObject var gifs: WallGIFStore
    let canvasSize: CGSize
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 0) {
                    NavigationLink {
                        GIFBrowserView(store: gifs)
                            .navigationBarHidden(true)
                    } label: {
                        HStack(spacing: 14) {
                            Text(".gif")
                                .font(.custom("Helvetica-Bold", size: 15))
                                .foregroundColor(.white)
                                .frame(width: 38, height: 30)
                                .background(Color.black)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("GIFCITIES")
                                    .font(.custom("Helvetica-Bold", size: 16))
                                Text("Find something strange for the wall")
                                    .font(.custom("Helvetica", size: 13))
                                    .foregroundColor(.black.opacity(0.56))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.black)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(WallWidgetPressStyle())
                    .accessibilityLabel("Open GifCities")

                    Rectangle()
                        .fill(Color.black)
                        .frame(height: 1)

                    Text("WIDGETS")
                        .font(.custom("Helvetica-Bold", size: 11))
                        .tracking(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                    ForEach(WallWidgetStore.catalog) { kind in
                        widgetRow(kind)
                        if kind != WallWidgetStore.catalog.last {
                            Rectangle()
                                .fill(Color.black.opacity(0.13))
                                .frame(height: 1)
                                .padding(.leading, 58)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.white.ignoresSafeArea())
            .navigationBarTitle("Add a widget", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") { dismiss() }
                .accessibilityIdentifier("wall.widget.picker.done"))
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.light)
    }

    private func widgetRow(_ kind: WallWidgetKind) -> some View {
        let added = store.contains(kind)
        return Button {
            guard !added else { return }
            _ = withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.84)) {
                store.add(kind, in: canvasSize)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.black)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.custom("Helvetica-Bold", size: 16))
                        .foregroundColor(.black)
                    Text(kind.detail)
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.black.opacity(0.56))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(added ? "ADDED" : "ADD")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .tracking(0.7)
                    .foregroundColor(added ? .black.opacity(0.32) : .white)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(added ? Color.black.opacity(0.07) : Color.black)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(WallWidgetPressStyle())
        .disabled(added)
        .accessibilityLabel(added ? "\(kind.title), added" : "Add \(kind.title)")
    }
}

struct WallWidgetElement: View {
    let item: WallWidgetItem
    @ObservedObject var store: WallWidgetStore
    @ObservedObject var layers: WallLayerStore
    @ObservedObject var dashboard: DashboardModel
    @ObservedObject var voice: DonVoiceController
    @Binding var isEditing: Bool
    let containerSize: CGSize
    let onRequestEdit: () -> Void
    let onInteractionChanged: (Bool) -> Void

    @State private var liveCenter: CGPoint?
    @State private var liveScale: CGFloat?
    @State private var liveRotation: Angle?
    @State private var dragOrigin: CGPoint?
    @State private var scaleOrigin: CGFloat?
    @State private var rotationOrigin: Angle?

    private var isSelected: Bool { isEditing && store.selectedID == item.id }
    private var displayScale: CGFloat { liveScale ?? CGFloat(item.scale) }
    private var displayRotation: Angle { liveRotation ?? .degrees(item.rotationDegrees) }
    private var displayCenter: CGPoint {
        liveCenter ?? clamped(item.center(in: containerSize), scale: displayScale)
    }

    var body: some View {
        ZStack(alignment: .top) {
            WallWidgetContent(kind: item.kind, dashboard: dashboard, voice: voice)
                .frame(width: item.kind.baseSize.width, height: item.kind.baseSize.height)
                .allowsHitTesting(!isEditing)

            if isSelected {
                editInteractionSurface
            } else if isEditing {
                WallObjectSelectionSurface(
                    accessibilityLabel: "Select \(item.kind.title) widget",
                    accessibilityIdentifier: "wall.widget.\(item.kind.rawValue).select",
                    action: select
                )
            }

            if isEditing {
                Rectangle()
                    .stroke(
                        Color.black.opacity(isSelected ? 1 : 0.22),
                        style: StrokeStyle(lineWidth: 1 / max(displayScale, 0.3), dash: isSelected ? [] : [4, 4])
                    )
                    .allowsHitTesting(false)
            }

        }
        .frame(width: item.kind.baseSize.width, height: item.kind.baseSize.height)
        .contentShape(Rectangle())
        .scaleEffect(displayScale)
        .rotationEffect(displayRotation)
        .position(displayCenter)
        .zIndex(layers.zIndex(for: .widget(item.id)))
        .shadow(color: isSelected ? Color.black.opacity(0.15) : .clear, radius: 10)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: isSelected)
        .wallObjectEditLongPress(enabled: !isEditing, action: onRequestEdit)
        .accessibilityElement(children: isEditing ? .ignore : .contain)
        .accessibilityLabel(isEditing ? "\(item.kind.title) widget" : "")
        .accessibilityHint(isEditing ? "Drag to move. Pinch to resize. Rotate with two fingers." : "Long-press to edit this widget.")
    }

    private var editInteractionSurface: some View {
        WallTransformGestureSurface(
            accessibilityLabel: "\(item.kind.title) widget",
            accessibilityIdentifier: "wall.widget.\(item.kind.rawValue)",
            accessibilityValue: transformAccessibilityValue,
            onTap: select,
            onPan: handlePan,
            onPinch: handlePinch,
            onRotation: handleRotation
        )
    }

    private var transformAccessibilityValue: String {
        "x:\(Int(displayCenter.x.rounded())),y:\(Int(displayCenter.y.rounded())),scale:\(String(format: "%.3f", displayScale)),rotation:\(String(format: "%.3f", displayRotation.degrees))"
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("wall-canvas"))
            .onChanged { value in
                guard isEditing else { return }
                if store.selectedID != item.id { store.selectedID = item.id }
                if dragOrigin == nil {
                    dragOrigin = displayCenter
                    liveCenter = displayCenter
                    onInteractionChanged(true)
                }
                guard let origin = dragOrigin else { return }
                liveCenter = clamped(
                    CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height),
                    scale: displayScale
                )
            }
            .onEnded { _ in
                guard isEditing, dragOrigin != nil else { return }
                commitTransform()
                dragOrigin = nil
                liveCenter = nil
                onInteractionChanged(false)
            }
    }

    private var selectionTapGesture: some Gesture {
        TapGesture()
            .onEnded {
                guard isEditing else { return }
                store.selectedID = item.id
            }
    }

    private var scaleGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isSelected else { return }
                if scaleOrigin == nil {
                    scaleOrigin = displayScale
                    onInteractionChanged(true)
                }
                liveScale = min(max((scaleOrigin ?? 1) * value, 0.45), 3)
                liveCenter = clamped(displayCenter, scale: displayScale)
            }
            .onEnded { _ in
                guard isSelected, scaleOrigin != nil else { return }
                commitTransform()
                scaleOrigin = nil
                liveScale = nil
                liveCenter = nil
                onInteractionChanged(false)
            }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard isSelected else { return }
                if rotationOrigin == nil {
                    rotationOrigin = displayRotation
                    onInteractionChanged(true)
                }
                liveRotation = (rotationOrigin ?? .zero) + value
            }
            .onEnded { _ in
                guard isSelected, rotationOrigin != nil else { return }
                commitTransform()
                rotationOrigin = nil
                liveRotation = nil
                onInteractionChanged(false)
            }
    }

    private func commitTransform() {
        store.update(
            item.id,
            center: displayCenter,
            scale: displayScale,
            rotation: displayRotation,
            in: containerSize
        )
    }

    private func select() {
        guard isEditing else { return }
        if store.selectedID != item.id {
            store.selectedID = item.id
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func handlePan(_ phase: WallTransformGesturePhase, _ translation: CGSize) {
        guard isEditing else { return }
        switch phase {
        case .began:
            select()
            dragOrigin = displayCenter
            liveCenter = displayCenter
            onInteractionChanged(true)
        case .changed:
            select()
            if dragOrigin == nil {
                dragOrigin = displayCenter
                liveCenter = displayCenter
                onInteractionChanged(true)
            }
            guard let origin = dragOrigin else { return }
            liveCenter = clamped(
                CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                scale: displayScale
            )
        case .ended:
            if let origin = dragOrigin {
                liveCenter = clamped(
                    CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                    scale: displayScale
                )
                commitTransform()
            }
            dragOrigin = nil
            liveCenter = nil
            onInteractionChanged(false)
        case .cancelled:
            dragOrigin = nil
            liveCenter = nil
            onInteractionChanged(false)
        }
    }

    private func handlePinch(_ phase: WallTransformGesturePhase, _ value: CGFloat) {
        guard isEditing else { return }
        switch phase {
        case .began:
            select()
            scaleOrigin = displayScale
            onInteractionChanged(true)
        case .changed:
            select()
            if scaleOrigin == nil { scaleOrigin = displayScale }
            liveScale = min(max((scaleOrigin ?? 1) * value, 0.45), 3)
            liveCenter = clamped(displayCenter, scale: displayScale)
        case .ended:
            commitTransform()
            scaleOrigin = nil
            liveScale = nil
            liveCenter = nil
            onInteractionChanged(false)
        case .cancelled:
            scaleOrigin = nil
            liveScale = nil
            liveCenter = nil
            onInteractionChanged(false)
        }
    }

    private func handleRotation(_ phase: WallTransformGesturePhase, _ value: Angle) {
        guard isEditing else { return }
        switch phase {
        case .began:
            select()
            rotationOrigin = displayRotation
            onInteractionChanged(true)
        case .changed:
            select()
            if rotationOrigin == nil { rotationOrigin = displayRotation }
            liveRotation = (rotationOrigin ?? .zero) + value
        case .ended:
            commitTransform()
            rotationOrigin = nil
            liveRotation = nil
            onInteractionChanged(false)
        case .cancelled:
            rotationOrigin = nil
            liveRotation = nil
            onInteractionChanged(false)
        }
    }

    private func clamped(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        let halfWidth = min(item.kind.baseSize.width * scale / 2, containerSize.width / 2)
        let halfHeight = min(item.kind.baseSize.height * scale / 2, containerSize.height / 2)
        return CGPoint(
            x: min(max(point.x, halfWidth), max(halfWidth, containerSize.width - halfWidth)),
            y: min(max(point.y, halfHeight), max(halfHeight, containerSize.height - halfHeight))
        )
    }
}

private struct WallWidgetPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct WallWidgetContent: View {
    let kind: WallWidgetKind
    @ObservedObject var dashboard: DashboardModel
    @ObservedObject var voice: DonVoiceController

    @ViewBuilder
    var body: some View {
        switch kind {
        case .date:
            DateWallWidget()
        case .monthCalendar:
            MonthCalendarWallWidget()
        case .dayProgress:
            TimeProgressWallWidget(period: .day)
        case .yearProgress:
            TimeProgressWallWidget(period: .year)
        case .battery:
            BatteryWallWidget()
        case .weatherDetails:
            WeatherDetailsWallWidget(snapshot: dashboard.weather)
        case .subwayStatus:
            SubwayStatusWallWidget(alerts: dashboard.transitAlerts)
        case .voiceAssistant:
            SiftConnectionWallWidget()
        case .focusTimer:
            FocusTimerWallWidget()
        case .stopwatch:
            StopwatchWallWidget()
        case .midnightCountdown:
            MidnightCountdownWallWidget()
        case .departureChecklist:
            DepartureChecklistWallWidget()
        case .wifiQRCode:
            WiFiQRWallWidget()
        case .moonPhase:
            MoonPhaseWallWidget()
        case .worldTime:
            WorldTimeWallWidget()
        case .retardCounter:
            RetardCounterWallWidget(count: voice.retardCount)
        case .weekStrip:
            WeekStripWallWidget()
        case .threeMonths:
            ThreeMonthsWallWidget()
        case .weekNumber:
            WeekNumberWallWidget()
        case .dayOfYear:
            DayOfYearWallWidget()
        case .astrologicalWeather, .mercuryMemo, .lacanianSignifier,
             .mirrorStage, .desireOfOther, .dreamResidue, .defenseMechanism,
             .projection, .superegoForecast, .strangeOracle, .unreliableNarrator:
            WallGeneratedStrangeWidget(kind: kind)
        case .dailyHoroscopes:
            DailyHoroscopesWallWidget()
        }
    }
}

func retardCounterShowsAngel(for count: Int) -> Bool {
    let digits = String(count)
    return digits.count > 1 && Set(digits).count == 1
}

private struct RetardCounterWallWidget: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 6) {
                if retardCounterShowsAngel(for: count) {
                    Text("👼")
                        .font(.system(size: 87))
                        .fixedSize()
                        .accessibilityHidden(true)
                }

                Text("\(count)")
                    .font(.custom("Helvetica-Bold", size: 82))
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
            }
            Text("retard counter")
                .font(.custom("Helvetica", size: 17))
        }
        .foregroundColor(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("retard counter, \(count)")
    }
}

private struct WallWidgetShell<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.custom("Helvetica-Bold", size: 11))
                .tracking(0.8)
                .foregroundColor(.black)
            Rectangle()
                .fill(Color.black)
                .frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(13)
    }
}

private struct DateWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text(WallWidgetDateFormatters.weekday.string(from: context.date).lowercased())
                    .font(.custom("Helvetica-Bold", size: 34))
                Text(WallWidgetDateFormatters.longDate.string(from: context.date))
                    .font(.custom("Helvetica", size: 16))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(13)
        }
    }
}

private struct MonthCalendarWallWidget: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30 * 60)) { context in
            let values = calendarValues(for: context.date)
            WallWidgetShell(title: values.title) {
                VStack(spacing: 5) {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Calendar.current.veryShortWeekdaySymbols, id: \.self) { symbol in
                            Text(symbol.uppercased())
                                .font(.custom("Helvetica-Bold", size: 10))
                                .foregroundColor(.black.opacity(0.45))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(values.days.enumerated()), id: \.offset) { _, day in
                            if let day {
                                Text("\(day)")
                                    .font(.custom(day == values.today ? "Helvetica-Bold" : "Helvetica", size: 13))
                                    .foregroundColor(day == values.today ? .white : .black)
                                    .frame(width: 25, height: 25)
                                    .background(day == values.today ? Color.black : Color.clear)
                                    .clipShape(Circle())
                            } else {
                                Color.clear.frame(width: 25, height: 25)
                            }
                        }
                    }
                }
            }
        }
    }

    private func calendarValues(for date: Date) -> (title: String, days: [Int?], today: Int) {
        let calendar = Calendar.current
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return ("Month", [], 0)
        }
        let leading = max(0, calendar.component(.weekday, from: start) - 1)
        let days = Array(repeating: nil as Int?, count: leading) + range.map(Optional.some)
        return (
            WallWidgetDateFormatters.monthYear.string(from: date),
            days,
            calendar.component(.day, from: date)
        )
    }
}

private struct TimeProgressWallWidget: View {
    enum Period { case day, year }
    let period: Period

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let value = progress(at: context.date)
            WallWidgetShell(title: period == .day ? "Day progress" : "Year progress") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.custom("Helvetica-Bold", size: 34))
                        .foregroundColor(.black)
                    WallWidgetMeter(value: value)
                    Text(period == .day ? "of today" : "of \(Calendar.current.component(.year, from: context.date))")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(.black.opacity(0.55))
                }
            }
        }
    }

    private func progress(at date: Date) -> Double {
        let calendar = Calendar.current
        switch period {
        case .day:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
            return min(max(date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
        case .year:
            let year = calendar.component(.year, from: date)
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? date
            let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? date
            return min(max(date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
        }
    }
}

private struct WallWidgetMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.1))
                Rectangle()
                    .fill(Color.black)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

private struct BatteryWallWidget: View {
    @State private var level: Float = -1
    @State private var state: UIDevice.BatteryState = .unknown

    var body: some View {
        WallWidgetShell(title: "iPad battery") {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(level < 0 ? "—" : "\(Int((level * 100).rounded()))%")
                    .font(.custom("Helvetica-Bold", size: 36))
                Text(stateLabel)
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(.black.opacity(0.56))
            }
            .foregroundColor(.black)
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            refresh()
        }
    }

    private var stateLabel: String {
        switch state {
        case .charging: return "charging"
        case .full: return "fully charged"
        case .unplugged: return "on battery"
        case .unknown: return "checking"
        @unknown default: return "checking"
        }
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
    }
}

private struct WeatherDetailsWallWidget: View {
    let snapshot: WeatherSnapshot?

    var body: some View {
        WallWidgetShell(title: "NYC weather") {
            if let snapshot {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: snapshot.expectsRain ? "umbrella" : "sun.max")
                        .font(.system(size: 31, weight: .light))
                        .frame(width: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(Int(snapshot.currentTemperature.rounded()))° now")
                            .font(.custom("Helvetica-Bold", size: 27))
                        Text("\(WeatherCodePresentation.label(for: snapshot.currentCode)) · \(Int(snapshot.high.rounded()))° / \(Int(snapshot.low.rounded()))° · \(snapshot.rainChance)% rain")
                            .font(.custom("Helvetica", size: 13))
                    }
                }
                .foregroundColor(.black)
            } else {
                Text("Fetching the forecast…")
                    .font(.custom("Helvetica", size: 14))
                    .foregroundColor(.black.opacity(0.5))
            }
        }
    }
}

private struct SubwayStatusWallWidget: View {
    let alerts: [TransitAlert]

    private var scopedAlerts: [TransitAlert] {
        WallTransitScope.alerts(from: alerts)
    }

    var body: some View {
        WallWidgetShell(title: "Subway status") {
            if !scopedAlerts.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    TransitAlertList(alerts: scopedAlerts, bulletDiameter: 18, fontSize: 11, rowHeight: 23)
                }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("No active L or M alerts")
                        .font(.custom("Helvetica-Bold", size: 17))
                }
                .foregroundColor(.black)
            }
        }
    }
}

private struct SiftConnectionWallWidget: View {
    @ObservedObject private var sift = SiftSonosService.shared

    var body: some View {
        WallWidgetShell(title: "Sift + Sonos") {
            HStack(spacing: 10) {
                Circle()
                    .fill(sift.isConnected ? Color.black : Color.black.opacity(0.18))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sift.isConnected ? "Sift connected" : "Connect in settings")
                        .font(.custom("Helvetica-Bold", size: 16))
                    Text(sift.status)
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(.black.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct FocusTimerWallWidget: View {
    @AppStorage("wall.widget.focus.end.v1") private var endTimestamp = 0.0
    @AppStorage("wall.widget.focus.remaining.v1") private var storedRemaining = 25.0 * 60

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let remaining = remaining(at: context.date)
            WallWidgetShell(title: "Focus timer") {
                HStack(spacing: 10) {
                    Button { toggle(at: context.date) } label: {
                        Text(Self.durationString(remaining))
                            .font(.custom("Helvetica-Bold", size: 38))
                            .monospacedDigit()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    }
                    .buttonStyle(WallWidgetPressStyle())

                    Button("reset") { reset() }
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(.black)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22)
                }
            }
        }
    }

    private func remaining(at date: Date) -> TimeInterval {
        guard endTimestamp > 0 else { return max(storedRemaining, 0) }
        return max(endTimestamp - date.timeIntervalSince1970, 0)
    }

    private func toggle(at date: Date) {
        let now = date.timeIntervalSince1970
        if endTimestamp > now {
            storedRemaining = max(endTimestamp - now, 0)
            endTimestamp = 0
        } else {
            let duration = storedRemaining > 0.5 ? storedRemaining : 25 * 60
            storedRemaining = duration
            endTimestamp = now + duration
        }
    }

    private func reset() {
        endTimestamp = 0
        storedRemaining = 25 * 60
    }

    static func durationString(_ value: TimeInterval) -> String {
        let seconds = max(Int(value.rounded(.up)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct StopwatchWallWidget: View {
    @AppStorage("wall.widget.stopwatch.started.v1") private var startedTimestamp = 0.0
    @AppStorage("wall.widget.stopwatch.elapsed.v1") private var storedElapsed = 0.0

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.1)) { context in
            WallWidgetShell(title: "Stopwatch") {
                HStack(spacing: 10) {
                    Button { toggle(at: context.date) } label: {
                        Text(Self.elapsedString(elapsed(at: context.date)))
                            .font(.custom("Helvetica-Bold", size: 31))
                            .monospacedDigit()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    }
                    .buttonStyle(WallWidgetPressStyle())

                    Button("reset") { reset() }
                        .font(.custom("Helvetica", size: 11))
                        .foregroundColor(.black)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22)
                }
            }
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        storedElapsed + (startedTimestamp > 0 ? max(date.timeIntervalSince1970 - startedTimestamp, 0) : 0)
    }

    private func toggle(at date: Date) {
        if startedTimestamp > 0 {
            storedElapsed = elapsed(at: date)
            startedTimestamp = 0
        } else {
            startedTimestamp = date.timeIntervalSince1970
        }
    }

    private func reset() {
        startedTimestamp = 0
        storedElapsed = 0
    }

    static func elapsedString(_ value: TimeInterval) -> String {
        let tenths = max(Int(value * 10), 0)
        let totalSeconds = tenths / 10
        return String(format: "%02d:%02d.%d", totalSeconds / 60, totalSeconds % 60, tenths % 10)
    }
}

private struct MidnightCountdownWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let interval = secondsUntilMidnight(from: context.date)
            WallWidgetShell(title: "Until midnight") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.durationString(interval))
                        .font(.custom("Helvetica-Bold", size: 34))
                        .monospacedDigit()
                        .foregroundColor(.black)
                    Text("left in today")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(.black.opacity(0.55))
                }
            }
        }
    }

    private func secondsUntilMidnight(from date: Date) -> TimeInterval {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? date
        return max(end.timeIntervalSince(date), 0)
    }

    static func durationString(_ value: TimeInterval) -> String {
        let seconds = max(Int(value), 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

private struct DepartureChecklistWallWidget: View {
    private let entries = ["keys", "wallet", "phone", "headphones"]
    @AppStorage("wall.widget.departure.mask.v1") private var completedMask = 0

    var body: some View {
        WallWidgetShell(title: "Before you leave") {
            VStack(spacing: 4) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    Button { completedMask ^= (1 << index) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isComplete(index) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16, weight: .medium))
                            Text(entry)
                                .font(.custom(isComplete(index) ? "Helvetica" : "Helvetica-Bold", size: 16))
                                .strikethrough(isComplete(index))
                            Spacer()
                        }
                        .foregroundColor(.black.opacity(isComplete(index) ? 0.38 : 1))
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(WallWidgetPressStyle())
                }
                Button("clear checks") { completedMask = 0 }
                    .font(.custom("Helvetica", size: 11))
                    .foregroundColor(.black.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func isComplete(_ index: Int) -> Bool {
        completedMask & (1 << index) != 0
    }
}

private struct WiFiQRWallWidget: View {
    @AppStorage("wall.note") private var note = "Wi‑Fi\nnetwork name\npassword"

    var body: some View {
        let credentials = WiFiCredentials(note: note)
        WallWidgetShell(title: "Guest Wi-Fi") {
            VStack(spacing: 7) {
                if let image = Self.qrImage(for: credentials.payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Wi-Fi QR code for \(credentials.networkLabel)")
                }
                Text(credentials.networkLabel)
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(.black)
                    .lineLimit(1)
            }
        }
    }

    private static let context = CIContext(options: nil)

    private static func qrImage(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct WiFiCredentials {
    let networkLabel: String
    let payload: String

    init(note: String) {
        let lines = note.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallbackLines = lines.filter {
            let value = $0.lowercased().replacingOccurrences(of: "‑", with: "-")
            return value != "wi-fi" && value != "wifi"
        }
        let explicitNetwork = Self.value(after: ["ssid", "network", "wi-fi", "wifi"], in: lines)
        let explicitPassword = Self.value(after: ["password", "pass", "pwd"], in: lines)
        let network = explicitNetwork ?? fallbackLines.first ?? "Guest Wi-Fi"
        let password = explicitPassword ?? (fallbackLines.count > 1 ? fallbackLines[1] : "")

        networkLabel = network
        if password.isEmpty {
            payload = note.isEmpty ? network : note
        } else {
            payload = "WIFI:T:WPA;S:\(Self.escape(network));P:\(Self.escape(password));;"
        }
    }

    private static func value(after prefixes: [String], in lines: [String]) -> String? {
        for line in lines {
            let lowered = line.lowercased().replacingOccurrences(of: "‑", with: "-")
            for prefix in prefixes {
                for separator in [":", "="] where lowered.hasPrefix("\(prefix)\(separator)") {
                    let index = line.index(line.startIndex, offsetBy: min(prefix.count + separator.count, line.count))
                    let value = line[index...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ":", with: "\\:")
    }
}

private struct MoonPhaseWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30 * 60)) { context in
            let phase = LunarPhase(date: context.date)
            WallWidgetShell(title: "Moon phase") {
                HStack(spacing: 16) {
                    MoonDisc(phase: phase.fraction)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(phase.name)
                            .font(.custom("Helvetica-Bold", size: 18))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(Int((phase.illumination * 100).rounded()))% illuminated")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(.black.opacity(0.55))
                    }
                    .foregroundColor(.black)
                }
            }
        }
    }
}

private struct MoonDisc: View {
    let phase: Double

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 1
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let rows = max(Int(radius * 2), 1)
            for row in 0...rows {
                let localY = -radius + CGFloat(row) * radius * 2 / CGFloat(rows)
                let edge = sqrt(max(radius * radius - localY * localY, 0))
                let left = center.x - edge
                let right = center.x + edge
                let y = center.y + localY
                let startX: CGFloat
                let endX: CGFloat
                if phase <= 0.5 {
                    let terminator = center.x + CGFloat(1 - 4 * phase) * edge
                    startX = terminator
                    endX = right
                } else {
                    let terminator = center.x + CGFloat(3 - 4 * phase) * edge
                    startX = left
                    endX = terminator
                }
                var line = Path()
                line.move(to: CGPoint(x: startX, y: y))
                line.addLine(to: CGPoint(x: endX, y: y))
                context.stroke(line, with: .color(.black), lineWidth: 1.4)
            }
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(.black),
                lineWidth: 1.5
            )
        }
        .accessibilityHidden(true)
    }
}

private struct LunarPhase {
    let fraction: Double
    let illumination: Double
    let name: String

    init(date: Date) {
        // A known new moon: 2000-01-06 18:14 UTC.
        let reference = Date(timeIntervalSince1970: 947_182_440)
        let synodicMonth = 29.530588853
        let days = date.timeIntervalSince(reference) / 86_400
        let normalized = ((days / synodicMonth).truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        fraction = normalized
        illumination = (1 - cos(normalized * 2 * .pi)) / 2
        switch normalized {
        case 0..<0.03, 0.97...1: name = "New moon"
        case 0.03..<0.22: name = "Waxing crescent"
        case 0.22..<0.28: name = "First quarter"
        case 0.28..<0.47: name = "Waxing gibbous"
        case 0.47..<0.53: name = "Full moon"
        case 0.53..<0.72: name = "Waning gibbous"
        case 0.72..<0.78: name = "Last quarter"
        default: name = "Waning crescent"
        }
    }
}

private struct WorldTimeWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            WallWidgetShell(title: "World time") {
                VStack(spacing: 7) {
                    timeRow("NEW YORK", zone: "America/New_York", date: context.date)
                    timeRow("LOS ANGELES", zone: "America/Los_Angeles", date: context.date)
                    timeRow("LONDON", zone: "Europe/London", date: context.date)
                }
            }
        }
    }

    private func timeRow(_ city: String, zone: String, date: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(city)
                .font(.custom("Helvetica-Bold", size: 11))
                .tracking(0.5)
            Spacer()
            Text(WallWidgetDateFormatters.time(in: zone).string(from: date))
                .font(.custom("Helvetica-Bold", size: 21))
                .monospacedDigit()
        }
        .foregroundColor(.black)
    }
}

private enum WallWidgetDateFormatters {
    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    static func time(in identifier: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(identifier: identifier)
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }
}
