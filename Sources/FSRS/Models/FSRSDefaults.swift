//
//  FSRSDefaults.swift
//
//  Created by nkq on 10/13/24.
//

import Foundation

public class FSRSDefaults {
    static let S_MIN = 0.001
    static let INIT_S_MAX = 100.0
    static let CLAMP_PARAMETERS = [
        [S_MIN, INIT_S_MAX] /** initial stability (Again) */,
        [S_MIN, INIT_S_MAX] /** initial stability (Hard) */,
        [S_MIN, INIT_S_MAX] /** initial stability (Good) */,
        [S_MIN, INIT_S_MAX] /** initial stability (Easy) */,
        [1.0, 10.0] /** initial difficulty (Good) */,
        [0.001, 4.0] /** initial difficulty (multiplier) */,
        [0.001, 4.0] /** difficulty (multiplier) */,
        [0.001, 0.75] /** difficulty (multiplier) */,
        [0.0, 4.5] /** stability (exponent) */,
        [0.0, 0.8] /** stability (negative power) */,
        [0.001, 3.5] /** stability (exponent) */,
        [0.001, 5.0] /** fail stability (multiplier) */,
        [0.001, 0.25] /** fail stability (negative power) */,
        [0.001, 0.9] /** fail stability (power) */,
        [0.0, 4.0] /** fail stability (exponent) */,
        [0.0, 1.0] /** stability (multiplier for Hard) */,
        [1.0, 6.0] /** stability (multiplier for Easy) */,
        [0.0, 2.0] /** short-term stability (exponent) */,
        [0.0, 2.0] /** short-term stability (exponent) */,
        [0.0, 0.8] /** short-term stability (negative power) */,
        [0.1, 0.8] /** forgetting curve decay */,
    ]

    var defaultRequestRetention = 0.9
    var defaultMaximumInterval = 36500.0
    let defaultW = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133,
        0.8334, 3.0194, 0.001, 1.8722, 0.1666,
        0.796, 1.4835, 0.0614, 0.2629, 1.6483,
        0.6014, 1.8729, 0.5425, 0.0912, 0.0658,
        0.1542,
    ]
    var defaultEnableFuzz = false
    var defaultEnableShortTerm = true

    var FSRSVersion: String = "v6.0.0 using FSRS-6"

    func generatorParameters(props: FSRSParameters? = nil) -> FSRSParameters {
        var w = defaultW
        if let p = props {
            if p.w.count == 21 {
                w = p.w
            } else if p.w.count == 19 {
                w = p.w
                w.append(0.0)
                w.append(0.5)
            } else if p.w.count == 17 {
                w = p.w
                w.append(0.0)
                w.append(0.0)
                w[4] = (w[5] * 2.0 + w[4]).toFixedNumber(8)
                w[5] = (log(w[5] * 3.0 + 1.0) / 3.0).toFixedNumber(8)
                w[6] = (w[6] + 0.5).toFixedNumber(8)
                w.append(0.0)
                w.append(0.5)
            }
        }
        w = w.enumerated().map({
            FSRSHelper.clamp($0.element, Self.CLAMP_PARAMETERS[$0.offset][0], Self.CLAMP_PARAMETERS[$0.offset][1])
        })
        return FSRSParameters(
            requestRetention: props?.requestRetention ?? defaultRequestRetention,
            maximumInterval: props?.maximumInterval ?? defaultMaximumInterval,
            w: w,
            enableFuzz: props?.enableFuzz ?? defaultEnableFuzz,
            enableShortTerm: props?.enableShortTerm ?? defaultEnableShortTerm
        )
    }

    
    /**
     * Create an empty card
     * @param now Current time
     * @param afterHandler Convert the result to another type. (Optional)
     * @example
     * ```
     * const card: Card = createEmptyCard(new Date());
     * ```
     * @example
     * ```
     * interface CardUnChecked
     *   extends Omit<Card, "due" | "last_review" | "state"> {
     *   cid: string;
     *   due: Date | number;
     *   last_review: Date | null | number;
     *   state: StateType;
     * }
     *
     * function cardAfterHandler(card: Card) {
     *      return {
     *       ...card,
     *       cid: "test001",
     *       state: State[card.state],
     *       last_review: card.last_review ?? null,
     *     } as CardUnChecked;
     * }
     *
     * const card: CardUnChecked = createEmptyCard(new Date(), cardAfterHandler);
     * ```
     */
    func createEmptyCard(now: Date = Date(), afterHandler: ((Card) -> Card)? = nil) -> Card {
        let card = Card(due: now)
        return afterHandler?(card) ?? card
    }
}
