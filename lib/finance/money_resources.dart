/// "Money in Islam" library shown in the Money screen.
///
/// Ayat: Tanzil Uthmani text (verbatim) with Saheeh International (Quran.com).
/// Hadith: sunnah.com English (hadith-api dataset), word for word.
/// Generated; edit the guides here, but keep quoted text unchanged.
library;

class MoneyResource {
  final String id, title, emoji, summary, markdown;
  const MoneyResource(this.id, this.title, this.emoji, this.summary, this.markdown);
}

const moneyDisclaimer = 'General guidance to help you plan, not a fatwa or personal financial advice.';

const moneyHadithRefs = <String>[
  "Sahih al-Bukhari 2072",
  "Sahih al-Bukhari 1429",
  "Sahih Muslim 2588",
  "Sahih al-Bukhari 6464",
  "Sahih al-Bukhari 2387",
  "Sahih al-Bukhari 2400",
  "Jami' at-Tirmidhi 1078",
  "Sahih Muslim 1598",
  "Jami' at-Tirmidhi 2517",
];

const moneyResources = <MoneyResource>[
  MoneyResource('ayat', 'Ayat on money', '📖', 'Moderation, charity, riba and debt in the Quran.', r'''# Ayat on money

Arabic: Tanzil Project Uthmani text (verbatim). English: Saheeh International (via Quran.com).

## Spending with moderation · Quran 25:67

وَٱلَّذِينَ إِذَآ أَنفَقُوا۟ لَمْ يُسْرِفُوا۟ وَلَمْ يَقْتُرُوا۟ وَكَانَ بَيْنَ ذَٰلِكَ قَوَامًا (67)

*And [they are] those who, when they spend, do so not excessively or sparingly but are ever, between that, [justly] moderate* (Al-Furqan 25:67)

## Not wasting · Quran 17:26–27

وَءَاتِ ذَا ٱلْقُرْبَىٰ حَقَّهُۥ وَٱلْمِسْكِينَ وَٱبْنَ ٱلسَّبِيلِ وَلَا تُبَذِّرْ تَبْذِيرًا (26)

إِنَّ ٱلْمُبَذِّرِينَ كَانُوٓا۟ إِخْوَٰنَ ٱلشَّيَٰطِينِ وَكَانَ ٱلشَّيْطَٰنُ لِرَبِّهِۦ كَفُورًا (27)

*And give the relative his right, and [also] the poor and the traveler, and do not spend wastefully.* (Al-Isra' 17:26)

*Indeed, the wasteful are brothers of the devils, and ever has Satan been to his Lord ungrateful.* (Al-Isra' 17:27)

## Balance in giving · Quran 17:29

وَلَا تَجْعَلْ يَدَكَ مَغْلُولَةً إِلَىٰ عُنُقِكَ وَلَا تَبْسُطْهَا كُلَّ ٱلْبَسْطِ فَتَقْعُدَ مَلُومًا مَّحْسُورًا (29)

*And do not make your hand [as] chained to your neck or extend it completely and [thereby] become blamed and insolvent.* (Al-Isra' 17:29)

## Charity grows · Quran 2:261

مَّثَلُ ٱلَّذِينَ يُنفِقُونَ أَمْوَٰلَهُمْ فِى سَبِيلِ ٱللَّهِ كَمَثَلِ حَبَّةٍ أَنۢبَتَتْ سَبْعَ سَنَابِلَ فِى كُلِّ سُنۢبُلَةٍ مِّا۟ئَةُ حَبَّةٍ وَٱللَّهُ يُضَٰعِفُ لِمَن يَشَآءُ وَٱللَّهُ وَٰسِعٌ عَلِيمٌ (261)

*The example of those who spend their wealth in the way of Allāh is like a seed [of grain] which grows seven spikes; in each spike is a hundred grains. And Allāh multiplies [His reward] for whom He wills. And Allāh is all-Encompassing and Knowing.* (Al-Baqarah 2:261)

## Riba (interest) · Quran 2:275

ٱلَّذِينَ يَأْكُلُونَ ٱلرِّبَوٰا۟ لَا يَقُومُونَ إِلَّا كَمَا يَقُومُ ٱلَّذِى يَتَخَبَّطُهُ ٱلشَّيْطَٰنُ مِنَ ٱلْمَسِّ ذَٰلِكَ بِأَنَّهُمْ قَالُوٓا۟ إِنَّمَا ٱلْبَيْعُ مِثْلُ ٱلرِّبَوٰا۟ وَأَحَلَّ ٱللَّهُ ٱلْبَيْعَ وَحَرَّمَ ٱلرِّبَوٰا۟ فَمَن جَآءَهُۥ مَوْعِظَةٌ مِّن رَّبِّهِۦ فَٱنتَهَىٰ فَلَهُۥ مَا سَلَفَ وَأَمْرُهُۥٓ إِلَى ٱللَّهِ وَمَنْ عَادَ فَأُو۟لَٰٓئِكَ أَصْحَٰبُ ٱلنَّارِ هُمْ فِيهَا خَٰلِدُونَ (275)

*Those who consume interest cannot stand [on the Day of Resurrection] except as one stands who is being beaten by Satan into insanity. That is because they say, "Trade is [just] like interest." But Allāh has permitted trade and has forbidden interest. So whoever has received an admonition from his Lord and desists may have what is past, and his affair rests with Allāh. But whoever returns [to dealing in interest or usury] - those are the companions of the Fire; they will abide eternally therein.* (Al-Baqarah 2:275)

## Give the debtor time · Quran 2:280

وَإِن كَانَ ذُو عُسْرَةٍ فَنَظِرَةٌ إِلَىٰ مَيْسَرَةٍ وَأَن تَصَدَّقُوا۟ خَيْرٌ لَّكُمْ إِن كُنتُمْ تَعْلَمُونَ (280)

*And if someone is in hardship, then [let there be] postponement until [a time of] ease. But if you give [from your right as] charity, then it is better for you, if you only knew.* (Al-Baqarah 2:280)

## Write debts down · Quran 2:282

يَٰٓأَيُّهَا ٱلَّذِينَ ءَامَنُوٓا۟ إِذَا تَدَايَنتُم بِدَيْنٍ إِلَىٰٓ أَجَلٍ مُّسَمًّى فَٱكْتُبُوهُ وَلْيَكْتُب بَّيْنَكُمْ كَاتِبٌۢ بِٱلْعَدْلِ وَلَا يَأْبَ كَاتِبٌ أَن يَكْتُبَ كَمَا عَلَّمَهُ ٱللَّهُ فَلْيَكْتُبْ وَلْيُمْلِلِ ٱلَّذِى عَلَيْهِ ٱلْحَقُّ وَلْيَتَّقِ ٱللَّهَ رَبَّهُۥ وَلَا يَبْخَسْ مِنْهُ شَيْـًٔا فَإِن كَانَ ٱلَّذِى عَلَيْهِ ٱلْحَقُّ سَفِيهًا أَوْ ضَعِيفًا أَوْ لَا يَسْتَطِيعُ أَن يُمِلَّ هُوَ فَلْيُمْلِلْ وَلِيُّهُۥ بِٱلْعَدْلِ وَٱسْتَشْهِدُوا۟ شَهِيدَيْنِ مِن رِّجَالِكُمْ فَإِن لَّمْ يَكُونَا رَجُلَيْنِ فَرَجُلٌ وَٱمْرَأَتَانِ مِمَّن تَرْضَوْنَ مِنَ ٱلشُّهَدَآءِ أَن تَضِلَّ إِحْدَىٰهُمَا فَتُذَكِّرَ إِحْدَىٰهُمَا ٱلْأُخْرَىٰ وَلَا يَأْبَ ٱلشُّهَدَآءُ إِذَا مَا دُعُوا۟ وَلَا تَسْـَٔمُوٓا۟ أَن تَكْتُبُوهُ صَغِيرًا أَوْ كَبِيرًا إِلَىٰٓ أَجَلِهِۦ ذَٰلِكُمْ أَقْسَطُ عِندَ ٱللَّهِ وَأَقْوَمُ لِلشَّهَٰدَةِ وَأَدْنَىٰٓ أَلَّا تَرْتَابُوٓا۟ إِلَّآ أَن تَكُونَ تِجَٰرَةً حَاضِرَةً تُدِيرُونَهَا بَيْنَكُمْ فَلَيْسَ عَلَيْكُمْ جُنَاحٌ أَلَّا تَكْتُبُوهَا وَأَشْهِدُوٓا۟ إِذَا تَبَايَعْتُمْ وَلَا يُضَآرَّ كَاتِبٌ وَلَا شَهِيدٌ وَإِن تَفْعَلُوا۟ فَإِنَّهُۥ فُسُوقٌۢ بِكُمْ وَٱتَّقُوا۟ ٱللَّهَ وَيُعَلِّمُكُمُ ٱللَّهُ وَٱللَّهُ بِكُلِّ شَىْءٍ عَلِيمٌ (282)

*O you who have believed, when you contract a debt for a specified term, write it down. And let a scribe write [it] between you in justice. Let no scribe refuse to write as Allāh has taught him. So let him write and let the one who has the obligation [i.e., the debtor] dictate. And let him fear Allāh, his Lord, and not leave anything out of it. But if the one who has the obligation is of limited understanding or weak or unable to dictate himself, then let his guardian dictate in justice. And bring to witness two witnesses from among your men. And if there are not two men [available], then a man and two women from those whom you accept as witnesses - so that if one of them [i.e., the women] errs, then the other can remind her. And let not the witnesses refuse when they are called upon. And do not be [too] weary to write it, whether it is small or large, for its [specified] term. That is more just in the sight of Allāh and stronger as evidence and more likely to prevent doubt between you, except when it is an immediate transaction which you conduct among yourselves. For [then] there is no blame upon you if you do not write it. And take witnesses when you conclude a contract. Let no scribe be harmed or any witness. For if you do so, indeed, it is [grave] disobedience in you. And fear Allāh. And Allāh teaches you. And Allāh is Knowing of all things.* (Al-Baqarah 2:282)

## Who receives zakat · Quran 9:60

إِنَّمَا ٱلصَّدَقَٰتُ لِلْفُقَرَآءِ وَٱلْمَسَٰكِينِ وَٱلْعَٰمِلِينَ عَلَيْهَا وَٱلْمُؤَلَّفَةِ قُلُوبُهُمْ وَفِى ٱلرِّقَابِ وَٱلْغَٰرِمِينَ وَفِى سَبِيلِ ٱللَّهِ وَٱبْنِ ٱلسَّبِيلِ فَرِيضَةً مِّنَ ٱللَّهِ وَٱللَّهُ عَلِيمٌ حَكِيمٌ (60)

*Zakāh expenditures are only for the poor and for the needy and for those employed for it and for bringing hearts together [for Islām] and for freeing captives [or slaves] and for those in debt and for the cause of Allāh and for the [stranded] traveler - an obligation [imposed] by Allāh. And Allāh is Knowing and Wise.* (At-Tawbah 9:60)

## Trust in Allah for provision · Quran 65:2–3

فَإِذَا بَلَغْنَ أَجَلَهُنَّ فَأَمْسِكُوهُنَّ بِمَعْرُوفٍ أَوْ فَارِقُوهُنَّ بِمَعْرُوفٍ وَأَشْهِدُوا۟ ذَوَىْ عَدْلٍ مِّنكُمْ وَأَقِيمُوا۟ ٱلشَّهَٰدَةَ لِلَّهِ ذَٰلِكُمْ يُوعَظُ بِهِۦ مَن كَانَ يُؤْمِنُ بِٱللَّهِ وَٱلْيَوْمِ ٱلْـَٔاخِرِ وَمَن يَتَّقِ ٱللَّهَ يَجْعَل لَّهُۥ مَخْرَجًا (2)

وَيَرْزُقْهُ مِنْ حَيْثُ لَا يَحْتَسِبُ وَمَن يَتَوَكَّلْ عَلَى ٱللَّهِ فَهُوَ حَسْبُهُۥٓ إِنَّ ٱللَّهَ بَٰلِغُ أَمْرِهِۦ قَدْ جَعَلَ ٱللَّهُ لِكُلِّ شَىْءٍ قَدْرًا (3)

*And when they have [nearly] fulfilled their term, either retain them according to acceptable terms or part with them according to acceptable terms. And bring to witness two just men from among you and establish the testimony for [the acceptance of] Allāh. That is instructed to whoever should believe in Allāh and the Last Day. And whoever fears Allāh - He will make for him a way out* (At-Talaq 65:2)

*And will provide for him from where he does not expect. And whoever relies upon Allāh - then He is sufficient for him. Indeed, Allāh will accomplish His purpose. Allāh has already set for everything a [decreed] extent.* (At-Talaq 65:3)
'''),
  MoneyResource('hadith', 'Hadith on money', '📜', 'Earning, giving and repaying.', r'''# Hadith on money

English translations as published on sunnah.com (via the hadith-api dataset), quoted word for word.

## Earning with your own hands

> Narrated Al-Miqdam:The Prophet (ﷺ) said, "Nobody has ever eaten a better meal than that which one has earned by working with one's own hands. The Prophet of Allah, David (ﷺ) used to eat from the earnings of his manual labor

— Sahih al-Bukhari 2072

## The upper hand

> Narrated Ibn `Umar:I heard Allah's Messenger (ﷺ) while he was on the pulpit speaking about charity, to abstain from asking others for some financial help and about begging others, saying, "The upper hand is better than the lower hand. The upper hand is that of the giver and the lower (hand) is that of the beggar

— Sahih al-Bukhari 1429

## Charity does not decrease wealth

> Abu Huraira reported Allah's Messenger (ﷺ) as saying:Charity does not decrease wealth, no one forgives another except that Allah increases his honor, and no one humbles himself for the sake of Allah except that Allah raises his status

— Sahih Muslim 2588

## Small and steady

> Narrated `Aisha:Allah's Messenger (ﷺ) said, "Do good deeds properly, sincerely and moderately and know that your deeds will not make you enter Paradise, and that the most beloved deed to Allah is the most regular and constant even if it were little

— Sahih al-Bukhari 6464

## Intending to repay

> Narrated Abu Huraira:The Prophet (ﷺ) said, "Whoever takes the money of the people with the intention of repaying it, Allah will repay it on his behalf, and whoever takes it in order to spoil it, then Allah will spoil him

— Sahih al-Bukhari 2387

## Paying debts on time

> Narrated Abu Huraira:Allah's Messenger (ﷺ) said, "Procrastination (delay) in repaying debts by a wealthy person is injustice

— Sahih al-Bukhari 2400

## Settling debts

> Abu Hurairah narrated that:The Messenger of Allah said: "The believer's soul is suspended by his debt until it is settled for him

— Jami' at-Tirmidhi 1078 (graded Sahih by Al-Albani)

## Interest

> Jabir said that Allah's Messenger (ﷺ) cursed the accepter of interest and its payer, and one who records it, and the two witnesses, and he said:They are all equal

— Sahih Muslim 1598

## Tie your camel

> Anas bin Malik narrated that a man said:"O Messenger of Allah! Shall I tie it and rely(upon Allah), or leave it loose and rely(upon Allah)?" He said: "Tie it and rely(upon Allah)." Other chains report similar narrations

— Jami' at-Tirmidhi 2517 (graded Hasan by Al-Albani)
'''),
  MoneyResource(
    "budget",
    "Build a simple budget",
    "\ud83e\uddfe",
    "Four steps to a monthly plan you can keep.",
    r'''# Build a simple budget

*General guidance to help you plan, not a fatwa or personal financial advice. For rulings on your situation, ask a qualified scholar.*

## 1. Know what comes in
Write down your monthly income after tax. If it changes month to month, use a careful (lower) average.

## 2. Pay the essentials first
List rent, bills, food, transport and family support. Give each a monthly limit in **Money → Budgets**.

## 3. Give and save before you spend
- Set aside sadaqah first, even a small fixed amount. The Prophet ﷺ said the most beloved deed is the most regular, even if little (Sahih al-Bukhari 6464).
- Move a fixed amount into a savings pot on payday, before spending on wants.

## 4. Spend the rest with moderation
Quran 25:67 describes those who spend "not excessively or sparingly". Use the remaining money for wants without guilt.

## Keep it going
- Log spending once a day; it takes a minute.
- Review once a month: which category went over, and should its limit change?
- A missed day is fine. Log what you remember and carry on.
''',
  ),
  MoneyResource(
    "emergency",
    "Emergency fund",
    "\ud83d\udedf",
    "A cushion of 3\u20136 months of essentials.",
    r'''# Emergency fund

*General guidance to help you plan, not a fatwa or personal financial advice. For rulings on your situation, ask a qualified scholar.*

An emergency fund is money kept aside for the unexpected: losing work, a repair, a medical bill. It keeps you from borrowing when life surprises you.

## How much
- **Start:** one month of essential spending.
- **Goal:** 3–6 months of essentials (rent, bills, food, transport).

## How
1. Create a savings pot called "Emergency fund" with that target.
2. Add a fixed amount every payday, even if small.
3. Keep it somewhere easy to reach but separate from spending money, ideally a non-interest current account or a Shariah-compliant savings account.
4. Only use it for real emergencies, then rebuild it.

"Tie it and rely on Allah" (Jami' at-Tirmidhi 2517): planning ahead and trusting Allah go together.
''',
  ),
  MoneyResource(
    "riba",
    "Avoiding riba",
    "\u2696\ufe0f",
    "Practical steps away from interest.",
    r'''# Avoiding riba (interest)

*General guidance to help you plan, not a fatwa or personal financial advice. For rulings on your situation, ask a qualified scholar.*

Quran 2:275 says "Allāh has permitted trade and has forbidden interest." Many everyday products carry interest, so it helps to plan around them.

## Everyday steps
- **Credit cards:** if you use one, pay the full balance every month so no interest is charged, or use a debit card.
- **Buy now, pay later:** check whether late fees or interest apply before using it.
- **Savings:** look for current accounts or Islamic banks that do not pay interest, or that use profit-sharing (mudarabah) accounts.
- **Big purchases (home, car):** ask Islamic banks about murabaha, ijara or diminishing musharakah, and have the contract checked by someone qualified.
- **Already in an interest debt?** Make a plan to pay it off as early as you can, and ask a scholar about your situation.

## Investing
Shariah-screened funds avoid companies in prohibited sectors and with high debt. Check who screens the fund and how.
''',
  ),
  MoneyResource(
    "zakat",
    "How zakat works",
    "\ud83c\udf19",
    "Nisab, the lunar year and the 2.5% rate.",
    r'''# How zakat works

*General guidance to help you plan, not a fatwa or personal financial advice. For rulings on your situation, ask a qualified scholar.*

Zakat is one of the five pillars of Islam: a yearly payment of 2.5% on qualifying wealth that has stayed above the nisab for one lunar (Hijri) year.

## Nisab
The minimum wealth before zakat is due:
- **Gold:** 85 grams of gold (the value changes with the gold price).
- **Silver:** 595 grams of silver. This is much lower, so more people pay zakat; many scholars recommend it for cash savings because it benefits the poor.

Pick one in **Money → Zakat**. Enter today's price per gram yourself; the app does not fetch prices.

## What counts
- Cash at home and in the bank, and savings
- Gold and silver you own
- Shares, funds and other investments (scholars differ on how much of a share's value counts)
- Business stock for sale
- Money owed to you that you expect to get back

Subtract debts due now, such as this month's payments.

## When
Choose a zakat date (the Hijri date your wealth first reached the nisab). Each Hijri year, on that date, calculate what you have and pay 2.5% of it if it's still above the nisab.

## Who receives it
Quran 9:60 names eight groups, including the poor and the needy, people in debt, and travellers in need.
''',
  ),
  MoneyResource("sadaqah", "A sadaqah habit", "\ud83e\udd32", "Small, regular giving.", r'''# A sadaqah habit

*General guidance to help you plan, not a fatwa or personal financial advice. For rulings on your situation, ask a qualified scholar.*

Sadaqah is voluntary charity: any amount, any time. "Charity does not decrease wealth" (Sahih Muslim 2588).

## Ideas
- A fixed amount every Friday.
- Round up each purchase and give the difference weekly.
- Give to family in need first; Quran 17:26 says "give the relative his right".
- Count non-money sadaqah too: a smile, helping someone, removing harm from a path.

Log it as **Sadaqah** in Money to see your weekly total. The amount matters less than keeping it regular.
'''),
  MoneyResource("debt", "Paying off debt", "\ud83d\udd17", "Write it down, plan it, pay it off.", r'''# Paying off debt

*General guidance to help you plan, not a fatwa or personal financial advice. For rulings on your situation, ask a qualified scholar.*

Quran 2:282 says to write debts down, with the amount and the term. Keeping a clear record protects both people.

## Plan
1. Add each debt in **Money → Debts**: who, how much, and when it's due.
2. Pay the minimum on all of them.
3. Put any extra towards one debt at a time: either the smallest (quick wins) or the one with interest (to leave riba sooner).
4. When one is cleared, move its payment to the next.

## Owed to you
Quran 2:280 encourages giving someone in hardship more time, and says forgiving the debt as charity is better.

## Motivation
"Whoever takes the money of the people with the intention of repaying it, Allah will repay it on his behalf" (Sahih al-Bukhari 2387).
'''),
];
