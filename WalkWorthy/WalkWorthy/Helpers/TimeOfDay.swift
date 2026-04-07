//
//  TimeOfDay.swift
//  WalkWorthy
//

import Foundation

enum TimeOfDay: Sendable {
    case morning, midday, night

    // morning: 5–10, midday: 11–17, night: 18–4
    static var current: TimeOfDay {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11:  return .morning
        case 11..<18: return .midday
        default:      return .night
        }
    }

    var imageName: String {
        switch self {
        case .morning: return "bgMorning"
        case .midday:  return "bgMidday"
        case .night:   return "bgNight"
        }
    }
}
