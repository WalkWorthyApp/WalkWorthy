//
//  DailyVerseCard.swift
//  WalkWorthy
//

import SwiftUI

struct DailyVerseCard: View {
    private static let verses: [(ref: String, text: String)] = [
        ("Philippians 4:13", "I can do all things through him who strengthens me."),
        ("Joshua 1:9", "Have I not commanded you? Be strong and courageous. Do not be frightened, and do not be dismayed, for the LORD your God is with you wherever you go.”"),
        ("Isaiah 40:31", "but they who wait for the LORD shall renew their strength; they shall mount up with wings like eagles; they shall run and not be weary; they shall walk and not faint."),
        ("Psalm 46:1", "God is our refuge and strength, a very present help in trouble."),
        ("Romans 8:28", "And we know that for those who love God all things work together for good, for those who are called according to his purpose."),
        ("Proverbs 3:5-6", "Trust in the LORD with all your heart, and do not lean on your own understanding. In all your ways acknowledge him, and he will make straight your paths."),
        ("Matthew 11:28", "Come to me, all who labor and are heavy laden, and I will give you rest."),
        ("2 Corinthians 12:9", "But he said to me, “My grace is sufficient for you, for my power is made perfect in weakness.” Therefore I will boast all the more gladly of my weaknesses, so that the power of Christ may rest upon me."),
        ("Psalm 23:1", "The LORD is my shepherd; I shall not want."),
        ("John 16:33", "I have said these things to you, that in me you may have peace. In the world you will have tribulation. But take heart; I have overcome the world.”"),
        ("Lamentations 3:22-23", "The steadfast love of the LORD never ceases; his mercies never come to an end; they are new every morning; great is your faithfulness."),
        ("Romans 15:13", "May the God of hope fill you with all joy and peace in believing, so that by the power of the Holy Spirit you may abound in hope."),
        ("Psalm 121:2", "My help comes from the LORD, who made heaven and earth."),
        ("Jeremiah 29:11", "For I know the plans I have for you, declares the LORD, plans for welfare and not for evil, to give you a future and a hope."),
        ("Galatians 6:9", "And let us not grow weary of doing good, for in due season we will reap, if we do not give up."),
        ("1 Peter 5:7", "casting all your anxieties on him, because he cares for you."),
        ("Psalm 34:18", "The LORD is near to the brokenhearted and saves the crushed in spirit."),
        ("Isaiah 41:10", "fear not, for I am with you; be not dismayed, for I am your God; I will strengthen you, I will help you, I will uphold you with my righteous right hand."),
        ("John 14:27", "Peace I leave with you; my peace I give to you. Not as the world gives do I give to you. Let not your hearts be troubled, neither let them be afraid."),
        ("Hebrews 11:1", "Now faith is the assurance of things hoped for, the conviction of things not seen."),
        ("Philippians 4:6-7", "do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God. And the peace of God, which surpasses all understanding, will guard your hearts and your minds in Christ Jesus."),
        ("Psalm 28:7", "The LORD is my strength and my shield; in him my heart trusts, and I am helped; my heart exults, and with my song I give thanks to him."),
        ("2 Timothy 1:7", "for God gave us a spirit not of fear but of power and love and self-control."),
        ("Matthew 6:34", "“Therefore do not be anxious about tomorrow, for tomorrow will be anxious for itself. Sufficient for the day is its own trouble."),
        ("Psalm 27:1", "The LORD is my light and my salvation; whom shall I fear? The LORD is the stronghold of my life; of whom shall I be afraid?"),
        ("Romans 8:38-39", "For I am sure that neither death nor life, nor angels nor rulers, nor things present nor things to come, nor powers, nor height nor depth, nor anything else in all creation, will be able to separate us from the love of God in Christ Jesus our Lord."),
        ("Psalm 119:105", "Your word is a lamp to my feet and a light to my path."),
        ("Colossians 3:23", "Whatever you do, work heartily, as for the Lord and not for men,"),
        ("James 1:5", "If any of you lacks wisdom, let him ask God, who gives generously to all without reproach, and it will be given him."),
        ("Psalm 9:9", "The LORD is a stronghold for the oppressed, a stronghold in times of trouble."),
        ("John 3:16", "“For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life."),
    ]

    private var todaysVerse: (ref: String, text: String) {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return Self.verses[(dayOfYear - 1) % Self.verses.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            HStack(spacing: scaled(8)) {
                Image(systemName: "book.closed.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Verse of the Day")
                    .font(.newsreaderSemiBoldItalic(size: scaled(15)))
            }

            Text(todaysVerse.text)
                .font(.newsreader(size: scaled(17)))
                .foregroundStyle(.primary)
                .lineSpacing(scaled(4))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: scaled(6)) {
                Text("— \(todaysVerse.ref)")
                    .font(.newsreaderSemiBoldItalic(size: scaled(13)))
                    .foregroundStyle(.secondary)
                Text("·  ESV")
                    .font(.newsreaderSemiBoldItalic(size: scaled(12)))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: scaled(16)).fill(Color.wwCardBackground))
    }
}
