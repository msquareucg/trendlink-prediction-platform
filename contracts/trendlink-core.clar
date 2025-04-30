;; TrendLink Core Contract
;; This contract manages prediction markets, user participation, and reward distribution
;; for the TrendLink prediction marketplace platform. It handles the complete lifecycle
;; of prediction markets from creation to resolution, enabling users to create and
;; participate in markets and earn rewards for accurate predictions.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-MARKET-NOT-FOUND (err u101))
(define-constant ERR-MARKET-CLOSED (err u102))
(define-constant ERR-MARKET-EXPIRED (err u103))
(define-constant ERR-MARKET-NOT-EXPIRED (err u104))
(define-constant ERR-MARKET-ALREADY-RESOLVED (err u105))
(define-constant ERR-INVALID-OUTCOME (err u106))
(define-constant ERR-INSUFFICIENT-STAKE (err u107))
(define-constant ERR-BELOW-MIN-STAKE (err u108))
(define-constant ERR-INVALID-STATE (err u109))
(define-constant ERR-DISPUTE-PERIOD-ACTIVE (err u110))
(define-constant ERR-DISPUTE-PERIOD-OVER (err u111))
(define-constant ERR-ALREADY-PARTICIPATED (err u112))
(define-constant ERR-CANNOT-CANCEL (err u113))
(define-constant ERR-NOT-CREATOR (err u114))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-MARKET-CREATION-STAKE u1000000) ;; 1 STX
(define-constant MIN-PARTICIPATION-STAKE u100000)    ;; 0.1 STX
(define-constant PLATFORM-FEE-PERCENT u5)            ;; 5% fee
(define-constant DISPUTE-PERIOD-BLOCKS u144)         ;; ~24 hours at 10min block time

;; Market status
(define-constant STATUS-OPEN u1)
(define-constant STATUS-EXPIRED u2)
(define-constant STATUS-RESOLVED u3)
(define-constant STATUS-CANCELLED u4)
(define-constant STATUS-DISPUTED u5)

;; Data maps
;; Stores core information about each prediction market
(define-map markets
  { market-id: uint }
  {
    creator: principal,
    question: (string-ascii 256),
    description: (string-utf8 1024),
    possible-outcomes: (list 20 (string-ascii 64)),
    creation-time: uint,
    expiration-time: uint, 
    resolution-time: uint,
    winning-outcome: (optional uint),
    status: uint,
    total-stake: uint,
    creation-stake: uint
  }
)

;; Tracks stakes per market and outcome
(define-map market-stakes
  { market-id: uint, outcome-idx: uint }
  { total-stake: uint }
)

;; Tracks individual user stakes per market
(define-map user-stakes
  { market-id: uint, user: principal, outcome-idx: uint }
  { amount: uint, claimed: bool }
)

;; Tracks user participation and accuracy
(define-map user-stats
  { user: principal }
  {
    total-stakes: uint,
    total-markets: uint,
    correct-predictions: uint,
    reputation-score: uint,
    total-winnings: uint
  }
)

;; Contract variables
(define-data-var market-nonce uint u0)
(define-data-var platform-treasury uint u0)
(define-data-var oracle principal CONTRACT-OWNER)
(define-data-var is-paused bool false)

;; Private functions

;; Get the next market ID and increment the nonce
(define-private (get-next-market-id)
  (let ((current-id (var-get market-nonce)))
    (var-set market-nonce (+ current-id u1))
    current-id
  )
)

;; Calculate the platform fee for a given amount
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount PLATFORM-FEE-PERCENT) u100)
)

;; Get or initialize user stats
(define-private (get-or-init-user-stats (user principal))
  (default-to
    {
      total-stakes: u0,
      total-markets: u0,
      correct-predictions: u0,
      reputation-score: u1000,
      total-winnings: u0
    }
    (map-get? user-stats { user: user })
  )
)

;; Update user stats after participation
(define-private (update-user-stats-participation (user principal) (stake-amount uint))
  (let ((user-data (get-or-init-user-stats user)))
    (map-set user-stats
      { user: user }
      (merge user-data {
        total-stakes: (+ (get total-stakes user-data) stake-amount),
        total-markets: (+ (get total-markets user-data) u1)
      })
    )
  )
)

;; Update user stats after winning
(define-private (update-user-stats-win (user principal) (winnings uint))
  (let ((user-data (get-or-init-user-stats user)))
    (map-set user-stats
      { user: user }
      (merge user-data {
        correct-predictions: (+ (get correct-predictions user-data) u1),
        reputation-score: (+ (get reputation-score user-data) u10),
        total-winnings: (+ (get total-winnings user-data) winnings)
      })
    )
  )
)

;; Validate that a market exists and is in the expected state
(define-private (validate-market-state (market-id uint) (expected-status uint))
  (match (map-get? markets { market-id: market-id })
    market (if (is-eq (get status market) expected-status)
      (ok market)
      (match (get status market)
        STATUS-CANCELLED ERR-MARKET-CLOSED
        STATUS-RESOLVED ERR-MARKET-ALREADY-RESOLVED
        STATUS-EXPIRED ERR-MARKET-EXPIRED
        STATUS-OPEN ERR-MARKET-NOT-EXPIRED
        ERR-INVALID-STATE
      )
    )
    ERR-MARKET-NOT-FOUND
  )
)

;; Validate that an outcome index is valid for a given market
(define-private (validate-outcome (market-id uint) (outcome-idx uint))
  (match (map-get? markets { market-id: market-id })
    market (if (< outcome-idx (len (get possible-outcomes market)))
      (ok true)
      ERR-INVALID-OUTCOME
    )
    ERR-MARKET-NOT-FOUND
  )
)

;; Check if market is expired but not yet resolved
(define-private (is-market-expired (market-id uint))
  (match (map-get? markets { market-id: market-id })
    market (and 
            (is-eq (get status market) STATUS-OPEN)
            (>= block-height (get expiration-time market)))
    false
  )
)

;; Read-only functions

;; Get market details
(define-read-only (get-market (market-id uint))
  (map-get? markets { market-id: market-id })
)

;; Get stake for a specific outcome in a market
(define-read-only (get-outcome-stake (market-id uint) (outcome-idx uint))
  (default-to { total-stake: u0 }
    (map-get? market-stakes { market-id: market-id, outcome-idx: outcome-idx })
  )
)

;; Get user stake for a specific outcome in a market
(define-read-only (get-user-stake (market-id uint) (user principal) (outcome-idx uint))
  (map-get? user-stakes 
    { market-id: market-id, user: user, outcome-idx: outcome-idx }
  )
)

;; Get user statistics
(define-read-only (get-user-statistics (user principal))
  (get-or-init-user-stats user)
)

;; Check if a user has participated in a market
(define-read-only (has-user-participated (market-id uint) (user principal))
  (match (get-market market-id)
    market (some 
      (filter 
        (compose not is-none)
        (map
          (lambda (outcome-idx)
            (map-get? user-stakes 
              { market-id: market-id, user: user, outcome-idx: outcome-idx }
            )
          )
          (list-to-uint-list (len (get possible-outcomes market)))
        )
      )
    )
    none
  )
)

;; Check if user has claimed for a market
(define-read-only (has-user-claimed (market-id uint) (user principal) (outcome-idx uint))
  (match (map-get? user-stakes { market-id: market-id, user: user, outcome-idx: outcome-idx })
    stake (get claimed stake)
    false
  )
)

;; Helper to convert list length to list of uint indices
(define-read-only (list-to-uint-list (len uint))
  (fold add-to-list (list) (range-of-n len))
)

;; Helper for list-to-uint-list
(define-read-only (add-to-list (result (list 20 uint)) (item uint))
  (unwrap-panic (as-max-len? (append result item) u20))
)

;; Helper for list-to-uint-list
(define-read-only (range-of-n (n uint))
  (if (is-eq n u0)
    (list)
    (unwrap-panic (as-max-len? (append (range-of-n (- n u1)) (- n u1)) u20))
  )
)

;; Public functions

;; Create a new prediction market
(define-public (create-market 
    (question (string-ascii 256))
    (description (string-utf8 1024))
    (possible-outcomes (list 20 (string-ascii 64)))
    (expiration-blocks uint)
    (stake uint)
  )
  (let 
    (
      (market-id (get-next-market-id))
      (expiration-time (+ block-height expiration-blocks))
    )
    ;; Validate inputs
    (asserts! (>= stake MIN-MARKET-CREATION-STAKE) ERR-BELOW-MIN-STAKE)
    (asserts! (> (len possible-outcomes) u1) ERR-INVALID-OUTCOME)
    (asserts! (not (var-get is-paused)) ERR-INVALID-STATE)
    
    ;; Transfer stake from user to contract
    (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
    
    ;; Create the market
    (map-set markets
      { market-id: market-id }
      {
        creator: tx-sender,
        question: question,
        description: description,
        possible-outcomes: possible-outcomes,
        creation-time: block-height,
        expiration-time: expiration-time,
        resolution-time: u0,
        winning-outcome: none,
        status: STATUS-OPEN,
        total-stake: u0,
        creation-stake: stake
      }
    )
    
    ;; Return the new market ID
    (ok market-id)
  )
)

;; Participate in a prediction market
(define-public (stake-on-outcome 
    (market-id uint) 
    (outcome-idx uint) 
    (amount uint)
  )
  (let 
    (
      (existing-stake (map-get? user-stakes 
        { market-id: market-id, user: tx-sender, outcome-idx: outcome-idx }))
    )
    ;; Validate market state and outcome
    (try! (validate-market-state market-id STATUS-OPEN))
    (try! (validate-outcome market-id outcome-idx))
    
    ;; Validate amount
    (asserts! (>= amount MIN-PARTICIPATION-STAKE) ERR-BELOW-MIN-STAKE)
    (asserts! (is-none existing-stake) ERR-ALREADY-PARTICIPATED)
    
    ;; Update market state with new stake
    (match (map-get? markets { market-id: market-id })
      market 
      (begin
        ;; Transfer tokens from user to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update total stake in market
        (map-set markets
          { market-id: market-id }
          (merge market { total-stake: (+ (get total-stake market) amount) })
        )
        
        ;; Update stake for this outcome
        (match (map-get? market-stakes { market-id: market-id, outcome-idx: outcome-idx })
          outcome-stake (map-set market-stakes
            { market-id: market-id, outcome-idx: outcome-idx }
            { total-stake: (+ (get total-stake outcome-stake) amount) }
          )
          (map-set market-stakes
            { market-id: market-id, outcome-idx: outcome-idx }
            { total-stake: amount }
          )
        )
        
        ;; Record user's stake
        (map-set user-stakes
          { market-id: market-id, user: tx-sender, outcome-idx: outcome-idx }
          { amount: amount, claimed: false }
        )
        
        ;; Update user stats
        (update-user-stats-participation tx-sender amount)
        
        (ok true)
      )
      ERR-MARKET-NOT-FOUND
    )
  )
)

;; Oracle or contract owner resolves a market
(define-public (resolve-market (market-id uint) (winning-outcome-idx uint))
  (let ((oracle-principal (var-get oracle)))
    ;; Check authorization
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) (is-eq tx-sender oracle-principal)) ERR-NOT-AUTHORIZED)
    
    ;; Validate that market is expired
    (match (map-get? markets { market-id: market-id })
      market 
      (begin
        (asserts! (or (is-eq (get status market) STATUS-EXPIRED) (>= block-height (get expiration-time market))) ERR-MARKET-NOT-EXPIRED)
        (asserts! (not (is-eq (get status market) STATUS-RESOLVED)) ERR-MARKET-ALREADY-RESOLVED)
        (asserts! (not (is-eq (get status market) STATUS-CANCELLED)) ERR-INVALID-STATE)
        (asserts! (< winning-outcome-idx (len (get possible-outcomes market))) ERR-INVALID-OUTCOME)
        
        ;; Update market with resolution
        (map-set markets
          { market-id: market-id }
          (merge market 
            { 
              status: STATUS-RESOLVED,
              resolution-time: block-height,
              winning-outcome: (some winning-outcome-idx)
            }
          )
        )
        
        (ok true)
      )
      ERR-MARKET-NOT-FOUND
    )
  )
)

;; Claim rewards for a resolved market
(define-public (claim-rewards (market-id uint))
  (match (map-get? markets { market-id: market-id })
    market 
    (begin
      ;; Verify market is resolved
      (asserts! (is-eq (get status market) STATUS-RESOLVED) ERR-INVALID-STATE)
      
      ;; Get winning outcome
      (match (get winning-outcome market)
        winning-outcome-idx
        (let
          ((user-stake (map-get? user-stakes 
            { market-id: market-id, user: tx-sender, outcome-idx: winning-outcome-idx })))
          
          ;; Check if user staked on winning outcome and hasn't claimed yet
          (match user-stake
            stake 
            (if (get claimed stake)
              ERR-ALREADY-PARTICIPATED
              (let 
                (
                  (stake-amount (get amount stake))
                  (outcome-stake (get-outcome-stake market-id winning-outcome-idx))
                  (total-market-stake (get total-stake market))
                  (user-proportion (/ (* stake-amount u1000000) (get total-stake outcome-stake)))
                  (reward-pool (- total-market-stake (calculate-platform-fee total-market-stake)))
                  (user-reward (/ (* reward-pool user-proportion) u1000000))
                )
                
                ;; Mark stake as claimed
                (map-set user-stakes
                  { market-id: market-id, user: tx-sender, outcome-idx: winning-outcome-idx }
                  (merge stake { claimed: true })
                )
                
                ;; Update platform treasury
                (var-set platform-treasury (+ (var-get platform-treasury) (calculate-platform-fee total-market-stake)))
                
                ;; Update user stats
                (update-user-stats-win tx-sender user-reward)
                
                ;; Transfer rewards to user
                (try! (as-contract (stx-transfer? user-reward tx-sender tx-sender)))
                
                (ok user-reward)
              )
            )
            ;; No stake found for this user on winning outcome
            (ok u0)
          )
        )
        ERR-INVALID-STATE
      )
    )
    ERR-MARKET-NOT-FOUND
  )
)

;; Expire a market that has passed its expiration time
(define-public (expire-market (market-id uint))
  (let ((oracle-principal (var-get oracle)))
    ;; Validate market state
    (match (map-get? markets { market-id: market-id })
      market 
      (begin
        (asserts! (is-eq (get status market) STATUS-OPEN) ERR-INVALID-STATE)
        (asserts! (>= block-height (get expiration-time market)) ERR-MARKET-NOT-EXPIRED)
        
        ;; Update market status to expired
        (map-set markets
          { market-id: market-id }
          (merge market { status: STATUS-EXPIRED })
        )
        
        (ok true)
      )
      ERR-MARKET-NOT-FOUND
    )
  )
)

;; Cancel a market (only callable by contract owner or market creator before expiration)
(define-public (cancel-market (market-id uint))
  (match (map-get? markets { market-id: market-id })
    market 
    (begin
      ;; Verify authorization
      (asserts! (or (is-eq tx-sender CONTRACT-OWNER) (is-eq tx-sender (get creator market))) ERR-NOT-AUTHORIZED)
      
      ;; Verify market state
      (asserts! (is-eq (get status market) STATUS-OPEN) ERR-INVALID-STATE)
      
      ;; If not contract owner, check if market has stakes before allowing cancellation
      (when (and (not (is-eq tx-sender CONTRACT-OWNER)) (> (get total-stake market) u0))
        (asserts! false ERR-CANNOT-CANCEL)
      )
      
      ;; Update market status to cancelled
      (map-set markets
        { market-id: market-id }
        (merge market { status: STATUS-CANCELLED })
      )
      
      ;; Return creation stake to creator
      (try! (as-contract (stx-transfer? (get creation-stake market) tx-sender (get creator market))))
      
      (ok true)
    )
    ERR-MARKET-NOT-FOUND
  )
)

;; Allow users to get refunds for cancelled markets
(define-public (refund-from-cancelled-market (market-id uint) (outcome-idx uint))
  (match (map-get? markets { market-id: market-id })
    market 
    (begin
      ;; Verify market is cancelled
      (asserts! (is-eq (get status market) STATUS-CANCELLED) ERR-INVALID-STATE)
      
      ;; Find user's stake
      (match (map-get? user-stakes { market-id: market-id, user: tx-sender, outcome-idx: outcome-idx })
        stake 
        (if (get claimed stake)
          ERR-ALREADY-PARTICIPATED
          (begin
            ;; Mark as claimed
            (map-set user-stakes
              { market-id: market-id, user: tx-sender, outcome-idx: outcome-idx }
              (merge stake { claimed: true })
            )
            
            ;; Transfer refund
            (try! (as-contract (stx-transfer? (get amount stake) tx-sender tx-sender)))
            
            (ok (get amount stake))
          )
        )
        (ok u0)
      )
    )
    ERR-MARKET-NOT-FOUND
  )
)

;; Administrative functions

;; Set oracle address
(define-public (set-oracle (new-oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set oracle new-oracle)
    (ok true)
  )
)

;; Pause/unpause contract
(define-public (set-paused (paused bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set is-paused paused)
    (ok true)
  )
)

;; Withdraw platform fees
(define-public (withdraw-fees (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= amount (var-get platform-treasury)) ERR-INSUFFICIENT-STAKE)
    
    (var-set platform-treasury (- (var-get platform-treasury) amount))
    (try! (as-contract (stx-transfer? amount tx-sender CONTRACT-OWNER)))
    
    (ok true)
  )
)