import SwiftUI

struct TodayView: View {
    @AppStorage("dailyStepGoal") private var goal = 8000
    @State private var motion = MotionService.shared

    private var progress: Double {
        goal > 0 ? min(1, Double(motion.steps) / Double(goal)) : 0
    }
    private var estimatedKcal: Double { Double(motion.steps) * 0.04 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RKSpacing.lg) {
                    ringCard
                    statsGrid
                    if !motion.available {
                        Text("Step tracking isn’t available on this device.")
                            .font(RKFont.caption)
                            .foregroundColor(RKColor.textMuted)
                            .padding(.horizontal, RKSpacing.md)
                    }
                }
                .padding(.vertical, RKSpacing.md)
                .readableWidth()
            }
            .navigationTitle("Today")
            .background(RKColor.background.ignoresSafeArea())
            .onAppear { motion.startToday() }
        }
    }

    private var ringCard: some View {
        ZStack {
            Circle().stroke(RKColor.surfaceElevated, lineWidth: 18)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(RKColor.accent, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: progress)
            VStack(spacing: 2) {
                Text("\(motion.steps)")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundColor(RKColor.textPrimary)
                    .contentTransition(.numericText())
                Text("of \(goal) steps")
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
            }
        }
        .frame(width: 220, height: 220)
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.lg)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private var statsGrid: some View {
        HStack(spacing: RKSpacing.md) {
            stat(String(format: "%.2f", motion.distanceMeters / 1000), "km", "map")
            stat("\(motion.flights)", "flights", "stairs")
            stat("\(Int(estimatedKcal))", "kcal", "flame.fill")
        }
        .padding(.horizontal, RKSpacing.md)
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(RKColor.accent)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(RKColor.textPrimary)
            Text(label)
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(RKSpacing.md)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
    }
}
