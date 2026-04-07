//
//  TimeOfDay.swift
//  WalkWorthy
//

import Foundation

enum TimeOfDay {
    case morning, midday, night

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
