--Check 1: Duplicate primary key check on flights and shipment_id 
SELECT count(*) as occurrence_count,
flight_id from flights
GROUP by flight_id
HAVING	count(*)>1;
 
SELECT count(*) as occurrence_count,
shipment_id from shipments
GROUP by shipment_id
HAVING	count(*)>1;

select 
count(DISTINCT(flight_id)) as distinct_count,
count(flight_id) as countid
from flights;

select 
count(DISTINCT(shipment_id)) as distinct_count,
count(shipment_id) as countid
from shipments;


--Identifying missing matches in foreign keys related to shipments, flights and warehouses

SELECT S.flight_id
FROM  shipments S
LEFT JOIN flights F on S.flight_id = F.flight_id 
WHERE S.flight_id is NULL;

SELECT S.origin_warehouse_id
FROM  shipments S
LEFT JOIN warehouses W on  S.origin_warehouse_id = W.warehouse_id 
WHERE S.origin_warehouse_id is NULL;

SELECT S.dest_warehouse_id
FROM  shipments S
LEFT JOIN warehouses W on  S.dest_warehouse_id = W.warehouse_id 
WHERE S.dest_warehouse_id is NULL;

SELECT F.dest_airport_id
FROM  flights F
LEFT JOIN airports A on  F.dest_airport_id = A.airport_id 
WHERE F.dest_airport_id is NULL;

--Check date validity 

SELECT * FROM shipments
where delivered_at is not NULL 
	and  delivered_at <  created_at;
	
Select  
            status,
	    	actual_departure,
	    	actual_arrival
		    from flights
	where 
          status='Cancelled' 
          and (actual_departure is NOT NULL or actual_arrival is NOT NULL);
		  
Select  
            status,
	    	actual_departure,
	    	actual_arrival
		    from flights
	where 
          status!='Cancelled' 
          and (actual_departure is NULL or actual_arrival is NULL);
		  
 SELECT MIN(delay_minutes), MAX(delay_minutes), AVG(delay_minutes) FROM flights;
 SELECT MIN(weight_kg), MAX(weight_kg), AVG(weight_kg) FROM shipments;
 SELECT MIN(declared_value_usd), MAX(declared_value_usd), AVG(declared_value_usd) FROM shipments;

SELECT category,
	   pax_capacity
FROM   aircraft
WHERE  (category = 'Freighter' and pax_capacity>0)
	  or	
	  (category!= 'Freighter' and (pax_capacity =0 or pax_capacity is NULL));
	 
	  
SELECT S.created_at,
	   F.scheduled_departure
FROM shipments S
LEFT JOIN flights F on S.flight_id = f.flight_id 
WHERE S.created_at>F.scheduled_departure;


------------------------- Business Questions ---------------------------


-- Q1: ROUTE DELAY ANALYSIS
-- Objective: Identify routes with highest average delays to support schedule padding 
-- and operational recovery planning. Filters for completed/delayed flights only (excludes cancelled).
-- Metrics: Average delay (minutes), max delay, count of severe delays (>60min), route distance, scheduled duration.
-- Business Impact: Helps ops prioritize resource allocation on problem routes.

SELECT  
	A.iata_code || ' - ' || A.name AS origin_airport,
    A2.iata_code || ' - ' || A2.name AS dest_airport,
    AVG(F.delay_minutes) AS avg_delay,
    COUNT(*) AS total_flights,
    MAX(F.distance_km) AS route_distance_km,
	ROUND((julianday(MAX(F.scheduled_arrival)) - julianday(MIN(F.scheduled_departure))) * 24, 1) AS route_duration_hours,
    COUNT(CASE WHEN F.delay_minutes > 60 THEN 1 END) AS flights_delayed_gt_60min
FROM flights F
    INNER JOIN airports A ON F.origin_airport_id = A.airport_id
    INNER JOIN airports A2 ON F.dest_airport_id = A2.airport_id
--WHERE F.status IN ('Completed', 'Delayed')
GROUP BY F.origin_airport_id, F.dest_airport_id
HAVING COUNT(*) > 10
ORDER BY avg(F.delay_minutes) DESC
LIMIT 10;



-- Q2: AIRLINE RELIABILITY RANKING
-- Objective: Benchmark airline performance by cancellation rate and overall disruption patterns.
-- Metrics: Cancellation rate (%), delay rate (%), diversion rate (%), completed rate (%).
-- Ranked by cancellation rate (DESC) to identify least reliable carriers.
-- Insight: Identifies whether disruption is airline-driven or system-wide (infrastructure/weather).
-- Business Impact: Supports partnership decisions and SLA management.

SELECT 
   
    A.name,
    A.carrier_type,
    COUNT(*) as total_flights,
    ROUND((SUM(CASE WHEN status = 'Cancelled' THEN 1 ELSE 0 END) * 100.0) / COUNT(*), 2) as cancellation_rate_pct,
    ROUND((SUM(CASE WHEN status = 'Delayed' THEN 1 ELSE 0 END) * 100.0) / COUNT(*), 2) as delay_rate_pct,
    ROUND((SUM(CASE WHEN status = 'Diverted' THEN 1 ELSE 0 END) * 100.0) / COUNT(*), 2) as diversion_rate_pct,
    ROUND((SUM(CASE WHEN status = 'Completed' THEN 1 ELSE 0 END) * 100.0) / COUNT(*), 2) as completed_rate_pct,	
	ROW_NUMBER() OVER (ORDER BY ROUND((SUM(CASE WHEN status = 'Cancelled' THEN 1 ELSE 0 END) * 100.0) / COUNT(*), 2) DESC) AS cancellation_rank

FROM  flights F
INNER join airlines A on F.airline_id =	A.airline_id
GROUP by F.airline_id, A.carrier_type
ORDER By cancellation_rate_pct DESC;


-- Q3: AIRPORT CONGESTION ANALYSIS
-- Objective: Identify airports with highest traffic volume (movements) to support capacity planning 
-- and slot management. Movements = inbound flights + outbound flights.
-- Methodology: UNION ALL to combine origin and destination traffic; airports serving as either departure 
-- or arrival point are counted separately then aggregated.
-- Metrics: Total movements, hub size classification, top 15 airports by traffic volume.
-- Business Impact: Guides resource allocation, identifies bottlenecks, supports partnership with ground handlers.
-- Note: High-congestion airports typically correlate with higher delay rates (see Q1 for route-level analysis).

WITH airport as
 (
	SELECT origin_airport_id as ID FROM flights
	UNION ALL
	SELECT dest_airport_id as ID FROM flights
),

 Rnk as (
 SELECT
	   count(A.ID) as movements,
	   A2.iata_code|| '-' || A2.name as Airport_Name,
	   A2.city,
	   A2.hub_size,
	   row_number() OVER (ORDER by count(A.ID)) as RNK
	   FROM airport A
	   INNER JOIN airports A2 on A.ID = A2.airport_id
	   GROUP By  A2.airport_id
	   ORDER By movements DESC
	   )
	   
SELECT * FROM Rnk
WHERE RNK > 15;

-- Q4: CONGESTION vs DELAY CORRELATION ANALYSIS
-- Objective: Investigate hypothesis that airport congestion directly impacts flight delays.
-- This bridges operational capacity planning with on-time performance metrics.
-- Methodology: Aggregate airport movements (from Q3) alongside average delay metrics for flights 
-- originating from or arriving at each airport. Correlation analysis at airport level (not route level).
-- Metrics: Total movements, average delay (minutes), delay rate (%), sample size (flight count).
-- Note: This is correlation analysis only - causation cannot be proven with SQL alone.
-- Business Impact: Validates whether infrastructure investment in high-congestion airports would 
-- reduce delays system-wide, or if delays are driven by external factors (weather, airline ops).
-- Expected Finding: Higher-congestion airports should show higher average delays (positive correlation).

WITH airport as
 (
	SELECT origin_airport_id as ID, delay_minutes FROM flights
	UNION ALL
	SELECT dest_airport_id as ID, delay_minutes FROM flights
),

 Rnk as (
 SELECT
	   count(A.ID) as movements,
	   round(avg(A.delay_minutes),2) as Delay,
	   A2.iata_code|| '-' || A2.name as Airport_Name,
	   A2.city,
	   A2.hub_size,
	   row_number() OVER (ORDER by count(A.ID)) as RNK
	   FROM airport A
	   INNER JOIN airports A2 on A.ID = A2.airport_id
	   GROUP By  A2.airport_id
	   ORDER By movements DESC
	   )
	   
SELECT * FROM Rnk
WHERE RNK > 15
ORDER by Delay DESC;

-- Q5: DELAY ROOT-CAUSE ANALYSIS BY DELAY REASON
-- Objective: Quantify which factors drive flight delays to inform operational mitigation strategies.
-- Methodology: Filter only delayed flights (status='Delayed'), then breakdown by delay_reason.
-- Metrics: Count and percentage distribution of each delay reason, ranked by frequency.
-- Delay Reason Categories: Weather, Air Traffic Control (ATC), Mechanical, Crew, Security, Late Inbound Aircraft, Other.
-- Business Impact: Identifies which delays are controllable (Mechanical, Crew, Security) vs external (Weather, ATC).
-- Controllable delays → investment in maintenance, crew planning, security processes.
-- External delays → inform customers of unavoidable causes, adjust schedule buffers accordingly.
-- Expected Insight: Likely Weather/ATC will dominate, but % of controllable delays reveals operational efficiency gaps


SELECT
    delay_reason,
    COUNT(*) as total_delayed_flights,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM flights WHERE status='Delayed'), 2) as pct_of_delayed
FROM flights
WHERE status = 'Delayed'
GROUP BY delay_reason
ORDER BY total_delayed_flights DESC;


-- Q6: WAREHOUSE LOSS AND RETURN RATE ANALYSIS
-- Objective: Identify underperforming warehouses by shipment loss/return rates to trigger 
-- operational audits or management changes. High loss rates indicate security, handling, or operational issues.
-- Methodology: For each warehouse (as origin_warehouse_id), calculate percentage of shipments with 
-- status='Lost' or 'Returned' relative to total outbound shipments from that warehouse.
-- Metrics: Total outbound shipments, count of Lost, count of Returned, combined loss/return rate (%),
-- warehouse code, capacity context, location (airport).
-- Business Impact: Loss/Return > 2% triggers investigation. Identifies rogue warehouses or systemic problems.
-- Note: Focus on origin warehouse (where cargo was shipped from), not destination.


SELECT 
		W.name,
		count (*) as total_shipment,
		SUM   (CASE WHEN status = 'Lost' THEN 1 ELSE 0 END) as total_lost,
		Round ((SUM(CASE WHEN status = 'Lost' THEN 1 ELSE 0 END)*100.0)/count(*),2) as Lost_rate

FROM shipments S
INNER JOIN warehouses W on S.origin_warehouse_id = W.warehouse_id
GROUP By W.warehouse_id
ORDER by Lost_rate DESC
LIMIT 15;


-- Q7: SEASONALITY ANALYSIS - MONTHLY TRENDS
-- Objective: Quantify holiday season impact (Nov-Dec) on flight volume, delays, and operational strain.
-- Compare peak months against baseline (Jan-Oct average) to inform capacity planning and staffing.
-- Hypothesis: November-December show elevated flight volume and higher delay rates due to holiday travel/shipping demand.
-- Methodology: Aggregate flights and shipments by calendar month (strftime '%m' on scheduled_departure/created_at).
-- Include ALL months (Jan-Dec) to show year-round context, then highlight Nov-Dec as peak season.
-- Metrics (per month):
--   - Total flights, cancellation rate (%), delay rate (%), average delay (minutes)
--   - Total shipments, average weight (kg), delivery rate (%), delayed shipment rate (%)
--   - Month-over-month comparison and % deviation from annual average
-- Business Impact: Validates whether Nov-Dec requires special resource allocation (extra staff, equipment).
-- Insight: If Nov-Dec show >15% higher volume or delay rates, investment in peak-capacity infrastructure is justified.
-- Note: Distinguish correlation (Nov-Dec IS busier) from causation (busyness CAUSES delays).
 
WITH monthly_data AS (
    SELECT
        strftime('%Y', scheduled_departure) AS year,
        strftime('%m', scheduled_departure) AS month,
        COUNT(*) AS total_flights
    FROM flights
    GROUP BY year, month
),
yearly_totals AS (
    SELECT
        year,
        SUM(total_flights) AS year_total_flights
    FROM monthly_data
    GROUP BY year
)
SELECT
    m.year,
    m.month,
    m.total_flights,
    y.year_total_flights,
    ROUND(100.0 * m.total_flights / y.year_total_flights, 2) AS pct_of_year
FROM monthly_data m
JOIN yearly_totals y ON m.year = y.year
WHERE m.month IN ('11', '12')
ORDER BY m.year, m.month;


-- Q8: SERVICE LEVEL VALIDATION
-- Objective: Validate whether premium (Express) service delivers better outcomes than Standard/Economy.
-- Metrics: Delivery rate (%), delay rate (%), loss rate (%) by service_type.
-- Insight: If Express doesn't outperform, pricing strategy needs review.

SELECT 
		service_type,
		count (*) as total_shipment,
		SUM   (CASE WHEN status = 'Lost' THEN 1 ELSE 0 END) as total_lost,
		SUM   (CASE WHEN status = 'Delivered' THEN 1 ELSE 0 END) as total_delivered,
		SUM   (CASE WHEN status = 'Delayed' THEN 1 ELSE 0 END) as total_delayed,
		Round ((SUM(CASE WHEN status = 'Lost' THEN 1 ELSE 0 END)*100.0)/count(*),2) as Lost_rate,
		Round ((SUM(CASE WHEN status = 'Delivered' THEN 1 ELSE 0 END)*100.0)/count(*),2) as Delivered_rate,
		Round ((SUM(CASE WHEN status = 'Delayed' THEN 1 ELSE 0 END)*100.0)/count(*),2) as Delayed_rate

FROM shipments 
GROUP by service_type;

-- Q9: AIRLINE CARGO VOLUME RANKING
-- Aggregate shipment weight by airline; compare Cargo/Integrator vs Passenger carriers.
-- Metrics: Total kg, shipment count, avg weight per shipment, by airline + carrier_type.

WITH total_weight as (
SELECT  A.name,
        carrier_type,
        sum(s.weight_kg) as total_kg,
        count(S.shipment_id) as shipment_count,
        avg(S.weight_kg) as avg_weight_per_shipment
        FROM  flights F
        INNER JOIN shipments S    on     F.flight_id=S.flight_id
        INNER JOIN airlines A    on  F.airline_id=A.airline_id
        GROUP by    A.name)

        SELECT 
                *,
                rank() OVER(    
                                PARTITION by carrier_type
                                ORDER by total_kg DESC) as Rnk
        FROM total_weight;

-- Q10: DISRUPTION CASCADE ANALYSIS
-- Do Diverted/Delayed flights increase cargo loss/delay rates?
-- Metrics: Loss rate (%), delay rate (%) of shipments by flight status (Completed/Delayed/Diverted).

SELECT 
    F.status AS flight_status,
    COUNT(S.shipment_id) AS total_shipments,
    ROUND(100.0 * SUM(CASE WHEN S.status = 'Lost' THEN 1 ELSE 0 END) / COUNT(S.shipment_id), 2) AS loss_rate_pct,
    ROUND(100.0 * SUM(CASE WHEN S.status = 'Delayed' THEN 1 ELSE 0 END) / COUNT(S.shipment_id), 2) AS delayed_rate_pct,
    ROUND(100.0 * SUM(CASE WHEN S.status = 'Delivered' THEN 1 ELSE 0 END) / COUNT(S.shipment_id), 2) AS delivered_rate_pct
FROM shipments S
INNER JOIN flights F ON S.flight_id = F.flight_id
GROUP BY F.status
ORDER BY loss_rate_pct DESC;




SELECT F.status,
       COUNT(*) AS n,
       COUNT(F.delay_minutes) AS non_null,
       ROUND(AVG(F.delay_minutes),2) AS avg_delay
FROM flights F
JOIN airports A  ON F.origin_airport_id = A.airport_id
JOIN airports A2 ON F.dest_airport_id  = A2.airport_id
WHERE A.iata_code='DFW' AND A2.iata_code='CDG'
GROUP BY F.status;