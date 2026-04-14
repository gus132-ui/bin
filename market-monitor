#!/bin/bash

# Skrypt wyświetlający aktualny kurs Bitcoin, CSPX.UK, EIMI.UK, CBU0.UK i IB01.UK

clear

while true; do
    clear
    echo "╔════════════════════════════════════════╗"
    echo "║       Market Price Monitor             ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    
    # Pobierz kurs Bitcoin z CoinGecko
    btc_response=$(curl -s 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=eur')
    
    if [ $? -eq 0 ] && [ -n "$btc_response" ]; then
        eur=$(echo $btc_response | grep -o '"eur":[0-9.]*' | cut -d':' -f2)
        
        if [ -n "$eur" ]; then
            echo "  💰 Bitcoin (BTC)"
            LC_NUMERIC=C printf "     Price: %'d €\n" "$eur"
            
            # Średnia cena zakupu
            avg_buy_price=71226.55
            gain=$(echo "scale=4; (($eur - $avg_buy_price) / $avg_buy_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Average buy price: %'.2f € (%.2f%%)\n" "$avg_buy_price" "$gain"
        else
            echo "  ❌ Bitcoin: Error parsing data"
        fi
    else
        echo "  ❌ Bitcoin: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kursy metali szlachetnych z Yahoo Finance
    gold_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/GC=F?interval=1d&range=1y' 2>/dev/null)
    gold_price=$(echo "$gold_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    gold_closes=$(echo "$gold_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    gold_month=$(echo "$gold_closes" | tail -31 | head -1)
    gold_year=$(echo "$gold_closes" | head -1)
    
    sleep 1
    silver_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/SI=F?interval=1d&range=1y' 2>/dev/null)
    silver_price=$(echo "$silver_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    silver_closes=$(echo "$silver_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    silver_month=$(echo "$silver_closes" | tail -31 | head -1)
    silver_year=$(echo "$silver_closes" | head -1)
    
    if [ -n "$gold_price" ] && [ -n "$silver_price" ]; then
        echo "  🥇 Precious Metals (per oz)"
        LC_NUMERIC=C printf "     Gold:     %.2f $\n" "$gold_price"
        if [ -n "$gold_month" ] && [ "$gold_month" != "null" ]; then
            month_change=$(echo "scale=4; (($gold_price - $gold_month) / $gold_month) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "       Month ago: %.2f $ (%.2f%%)\n" "$gold_month" "$month_change"
        fi
        if [ -n "$gold_year" ] && [ "$gold_year" != "null" ]; then
            year_change=$(echo "scale=4; (($gold_price - $gold_year) / $gold_year) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "       Year ago: %.2f $ (%.2f%%)\n" "$gold_year" "$year_change"
        fi
        
        LC_NUMERIC=C printf "     Silver:   %.2f $\n" "$silver_price"
        if [ -n "$silver_month" ] && [ "$silver_month" != "null" ]; then
            month_change=$(echo "scale=4; (($silver_price - $silver_month) / $silver_month) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "       Month ago: %.2f $ (%.2f%%)\n" "$silver_month" "$month_change"
        fi
        if [ -n "$silver_year" ] && [ "$silver_year" != "null" ]; then
            year_change=$(echo "scale=4; (($silver_price - $silver_year) / $silver_year) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "       Year ago: %.2f $ (%.2f%%)\n" "$silver_year" "$year_change"
        fi
        
        echo ""
        # Oblicz Gold/Silver Ratio
        gold_silver_ratio=$(echo "scale=4; $gold_price / $silver_price" | LC_NUMERIC=C bc)
        
        echo "     📊 Metal Ratios:"
        LC_NUMERIC=C printf "        Gold/Silver: %.2f\n" "$gold_silver_ratio"
        
        # Interpretacja Gold/Silver ratio
        ratio_int=$(echo "scale=0; $gold_silver_ratio / 1" | LC_NUMERIC=C bc)
        if [ "$ratio_int" -gt 80 ]; then
            echo "        → Silver undervalued vs Gold"
        elif [ "$ratio_int" -lt 50 ]; then
            echo "        → Gold undervalued vs Silver"
        fi
    else
        echo "  ❌ Metals: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kurs CSPX.UK (iShares Core S&P 500)
    sleep 1
    cspx_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/CSPX.L?interval=1d&range=2y' 2>/dev/null)
    cspx_price=$(echo "$cspx_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    cspx_currency=$(echo "$cspx_response" | grep -o '"currency":"[A-Z]*"' | head -1 | cut -d'"' -f4)
    cspx_closes=$(echo "$cspx_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    cspx_prev_day=$(echo "$cspx_closes" | tail -2 | head -1)
    cspx_week_price=$(echo "$cspx_closes" | tail -7 | head -1)
    cspx_2week_price=$(echo "$cspx_closes" | tail -14 | head -1)
    cspx_month_price=$(echo "$cspx_closes" | tail -31 | head -1)
    cspx_13month_price=$(echo "$cspx_closes" | tail -283 | head -1)
    
    if [ -n "$cspx_price" ]; then
        echo "  📊 iShares Core S&P 500 (CSPX.L)"
        echo "     ISIN: IE00B5BMR087"
        
        # Determine currency symbol
        if [ "$cspx_currency" = "GBP" ]; then
            currency_symbol="£"
        elif [ "$cspx_currency" = "EUR" ]; then
            currency_symbol="€"
        elif [ "$cspx_currency" = "USD" ]; then
            currency_symbol="$"
        else
            currency_symbol="$cspx_currency"
        fi
        
        LC_NUMERIC=C printf "     Price: %.2f %s\n" "$cspx_price" "$currency_symbol"
        
        if [ -n "$cspx_prev_day" ] && [ "$cspx_prev_day" != "null" ]; then
            prev_change=$(echo "scale=4; (($cspx_price - $cspx_prev_day) / $cspx_prev_day) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Previous day: %.2f %s (%.2f%%)\n" "$cspx_prev_day" "$currency_symbol" "$prev_change"
        fi
        if [ -n "$cspx_week_price" ] && [ "$cspx_week_price" != "null" ]; then
            week_change=$(echo "scale=4; (($cspx_price - $cspx_week_price) / $cspx_week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Week ago: %.2f %s (%.2f%%)\n" "$cspx_week_price" "$currency_symbol" "$week_change"
        fi
        if [ -n "$cspx_2week_price" ] && [ "$cspx_2week_price" != "null" ]; then
            week2_change=$(echo "scale=4; (($cspx_price - $cspx_2week_price) / $cspx_2week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     2 weeks ago: %.2f %s (%.2f%%)\n" "$cspx_2week_price" "$currency_symbol" "$week2_change"
        fi
        if [ -n "$cspx_month_price" ] && [ "$cspx_month_price" != "null" ]; then
            month_change=$(echo "scale=4; (($cspx_price - $cspx_month_price) / $cspx_month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Month ago: %.2f %s (%.2f%%)\n" "$cspx_month_price" "$currency_symbol" "$month_change"
        fi
        if [ -n "$cspx_month_price" ] && [ "$cspx_month_price" != "null" ] && [ -n "$cspx_13month_price" ] && [ "$cspx_13month_price" != "null" ]; then
            year_gain=$(echo "scale=4; (($cspx_month_price - $cspx_13month_price) / $cspx_13month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     12-month gain (13m ago to 1m ago): %.2f%%\n" "$year_gain"
        fi
    else
        echo "  ❌ CSPX.L: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kurs EIMI.UK (iShares Core MSCI EM IMI)
    sleep 1
    eimi_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/EIMI.L?interval=1d&range=2y' 2>/dev/null)
    eimi_price=$(echo "$eimi_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    eimi_currency=$(echo "$eimi_response" | grep -o '"currency":"[A-Z]*"' | head -1 | cut -d'"' -f4)
    eimi_closes=$(echo "$eimi_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    eimi_prev_day=$(echo "$eimi_closes" | tail -2 | head -1)
    eimi_week_price=$(echo "$eimi_closes" | tail -7 | head -1)
    eimi_2week_price=$(echo "$eimi_closes" | tail -14 | head -1)
    eimi_month_price=$(echo "$eimi_closes" | tail -31 | head -1)
    eimi_13month_price=$(echo "$eimi_closes" | tail -283 | head -1)
    
    if [ -n "$eimi_price" ]; then
        echo "  📈 iShares Core MSCI EM IMI (EIMI.L)"
        echo "     ISIN: IE00BKM4GZ66"
        
        # Determine currency symbol
        if [ "$eimi_currency" = "GBP" ]; then
            currency_symbol="£"
        elif [ "$eimi_currency" = "EUR" ]; then
            currency_symbol="€"
        elif [ "$eimi_currency" = "USD" ]; then
            currency_symbol="$"
        else
            currency_symbol="$eimi_currency"
        fi
        
        LC_NUMERIC=C printf "     Price: %.2f %s\n" "$eimi_price" "$currency_symbol"
        
        if [ -n "$eimi_prev_day" ] && [ "$eimi_prev_day" != "null" ]; then
            prev_change=$(echo "scale=4; (($eimi_price - $eimi_prev_day) / $eimi_prev_day) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Previous day: %.2f %s (%.2f%%)\n" "$eimi_prev_day" "$currency_symbol" "$prev_change"
        fi
        if [ -n "$eimi_week_price" ] && [ "$eimi_week_price" != "null" ]; then
            week_change=$(echo "scale=4; (($eimi_price - $eimi_week_price) / $eimi_week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Week ago: %.2f %s (%.2f%%)\n" "$eimi_week_price" "$currency_symbol" "$week_change"
        fi
        if [ -n "$eimi_2week_price" ] && [ "$eimi_2week_price" != "null" ]; then
            week2_change=$(echo "scale=4; (($eimi_price - $eimi_2week_price) / $eimi_2week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     2 weeks ago: %.2f %s (%.2f%%)\n" "$eimi_2week_price" "$currency_symbol" "$week2_change"
        fi
        if [ -n "$eimi_month_price" ] && [ "$eimi_month_price" != "null" ]; then
            month_change=$(echo "scale=4; (($eimi_price - $eimi_month_price) / $eimi_month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Month ago: %.2f %s (%.2f%%)\n" "$eimi_month_price" "$currency_symbol" "$month_change"
        fi
        if [ -n "$eimi_month_price" ] && [ "$eimi_month_price" != "null" ] && [ -n "$eimi_13month_price" ] && [ "$eimi_13month_price" != "null" ]; then
            year_gain=$(echo "scale=4; (($eimi_month_price - $eimi_13month_price) / $eimi_13month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     12-month gain (13m ago to 1m ago): %.2f%%\n" "$year_gain"
        fi
    else
        echo "  ❌ EIMI.L: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kurs CBU0.UK (iShares Core Corporate Bond)
    sleep 1
    cbu0_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/CBU0.L?interval=1d&range=2y' 2>/dev/null)
    cbu0_price=$(echo "$cbu0_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    cbu0_currency=$(echo "$cbu0_response" | grep -o '"currency":"[A-Z]*"' | head -1 | cut -d'"' -f4)
    cbu0_closes=$(echo "$cbu0_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    cbu0_prev_day=$(echo "$cbu0_closes" | tail -2 | head -1)
    cbu0_week_price=$(echo "$cbu0_closes" | tail -7 | head -1)
    cbu0_2week_price=$(echo "$cbu0_closes" | tail -14 | head -1)
    cbu0_month_price=$(echo "$cbu0_closes" | tail -31 | head -1)
    cbu0_13month_price=$(echo "$cbu0_closes" | tail -283 | head -1)
    
    if [ -n "$cbu0_price" ]; then
        echo "  💼 iShares Core Corporate Bond (CBU0.L)"
        echo "     ISIN: IE00BD1DJ122"
        
        # Determine currency symbol
        if [ "$cbu0_currency" = "GBP" ]; then
            currency_symbol="£"
        elif [ "$cbu0_currency" = "EUR" ]; then
            currency_symbol="€"
        elif [ "$cbu0_currency" = "USD" ]; then
            currency_symbol="$"
        else
            currency_symbol="$cbu0_currency"
        fi
        
        LC_NUMERIC=C printf "     Price: %.2f %s\n" "$cbu0_price" "$currency_symbol"
        
        if [ -n "$cbu0_prev_day" ] && [ "$cbu0_prev_day" != "null" ]; then
            prev_change=$(echo "scale=4; (($cbu0_price - $cbu0_prev_day) / $cbu0_prev_day) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Previous day: %.2f %s (%.2f%%)\n" "$cbu0_prev_day" "$currency_symbol" "$prev_change"
        fi
        if [ -n "$cbu0_week_price" ] && [ "$cbu0_week_price" != "null" ]; then
            week_change=$(echo "scale=4; (($cbu0_price - $cbu0_week_price) / $cbu0_week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Week ago: %.2f %s (%.2f%%)\n" "$cbu0_week_price" "$currency_symbol" "$week_change"
        fi
        if [ -n "$cbu0_2week_price" ] && [ "$cbu0_2week_price" != "null" ]; then
            week2_change=$(echo "scale=4; (($cbu0_price - $cbu0_2week_price) / $cbu0_2week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     2 weeks ago: %.2f %s (%.2f%%)\n" "$cbu0_2week_price" "$currency_symbol" "$week2_change"
        fi
        if [ -n "$cbu0_month_price" ] && [ "$cbu0_month_price" != "null" ]; then
            month_change=$(echo "scale=4; (($cbu0_price - $cbu0_month_price) / $cbu0_month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Month ago: %.2f %s (%.2f%%)\n" "$cbu0_month_price" "$currency_symbol" "$month_change"
        fi
        if [ -n "$cbu0_month_price" ] && [ "$cbu0_month_price" != "null" ] && [ -n "$cbu0_13month_price" ] && [ "$cbu0_13month_price" != "null" ]; then
            year_gain=$(echo "scale=4; (($cbu0_month_price - $cbu0_13month_price) / $cbu0_13month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     12-month gain (13m ago to 1m ago): %.2f%%\n" "$year_gain"
        fi
    else
        echo "  ❌ CBU0.L: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kurs IB01.UK (iShares Treasury Bond 0-1yr)
    sleep 1
    ib01_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/IB01.L?interval=1d&range=2y' 2>/dev/null)
    ib01_price=$(echo "$ib01_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    ib01_currency=$(echo "$ib01_response" | grep -o '"currency":"[A-Z]*"' | head -1 | cut -d'"' -f4)
    ib01_closes=$(echo "$ib01_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    ib01_prev_day=$(echo "$ib01_closes" | tail -2 | head -1)
    ib01_week_price=$(echo "$ib01_closes" | tail -7 | head -1)
    ib01_2week_price=$(echo "$ib01_closes" | tail -14 | head -1)
    ib01_month_price=$(echo "$ib01_closes" | tail -31 | head -1)
    ib01_13month_price=$(echo "$ib01_closes" | tail -283 | head -1)
    
    if [ -n "$ib01_price" ]; then
        echo "  🏦 iShares Treasury Bond 0-1yr (IB01.L)"
        echo "     ISIN: IE00B4WXJJ64"
        
        # Determine currency symbol
        if [ "$ib01_currency" = "GBP" ]; then
            currency_symbol="£"
        elif [ "$ib01_currency" = "EUR" ]; then
            currency_symbol="€"
        elif [ "$ib01_currency" = "USD" ]; then
            currency_symbol="$"
        else
            currency_symbol="$ib01_currency"
        fi
        
        LC_NUMERIC=C printf "     Price: %.2f %s\n" "$ib01_price" "$currency_symbol"
        
        if [ -n "$ib01_prev_day" ] && [ "$ib01_prev_day" != "null" ]; then
            prev_change=$(echo "scale=4; (($ib01_price - $ib01_prev_day) / $ib01_prev_day) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Previous day: %.2f %s (%.2f%%)\n" "$ib01_prev_day" "$currency_symbol" "$prev_change"
        fi
        if [ -n "$ib01_week_price" ] && [ "$ib01_week_price" != "null" ]; then
            week_change=$(echo "scale=4; (($ib01_price - $ib01_week_price) / $ib01_week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Week ago: %.2f %s (%.2f%%)\n" "$ib01_week_price" "$currency_symbol" "$week_change"
        fi
        if [ -n "$ib01_2week_price" ] && [ "$ib01_2week_price" != "null" ]; then
            week2_change=$(echo "scale=4; (($ib01_price - $ib01_2week_price) / $ib01_2week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     2 weeks ago: %.2f %s (%.2f%%)\n" "$ib01_2week_price" "$currency_symbol" "$week2_change"
        fi
        if [ -n "$ib01_month_price" ] && [ "$ib01_month_price" != "null" ]; then
            month_change=$(echo "scale=4; (($ib01_price - $ib01_month_price) / $ib01_month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Month ago: %.2f %s (%.2f%%)\n" "$ib01_month_price" "$currency_symbol" "$month_change"
        fi
        if [ -n "$ib01_month_price" ] && [ "$ib01_month_price" != "null" ] && [ -n "$ib01_13month_price" ] && [ "$ib01_13month_price" != "null" ]; then
            year_gain=$(echo "scale=4; (($ib01_month_price - $ib01_13month_price) / $ib01_13month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     12-month gain (13m ago to 1m ago): %.2f%%\n" "$year_gain"
        fi
    else
        echo "  ❌ IB01.L: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kurs BETAW20TR (Beta ETF WIG20TR)
    sleep 1
    betaw20_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/ETFBW20TR.WA?interval=1d&range=2y' 2>/dev/null)
    betaw20_price=$(echo "$betaw20_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    betaw20_currency=$(echo "$betaw20_response" | grep -o '"currency":"[A-Z]*"' | head -1 | cut -d'"' -f4)
    betaw20_closes=$(echo "$betaw20_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    betaw20_prev_day=$(echo "$betaw20_closes" | tail -2 | head -1)
    betaw20_week_price=$(echo "$betaw20_closes" | tail -7 | head -1)
    betaw20_2week_price=$(echo "$betaw20_closes" | tail -14 | head -1)
    betaw20_month_price=$(echo "$betaw20_closes" | tail -31 | head -1)
    betaw20_7month_price=$(echo "$betaw20_closes" | tail -157 | head -1)
    betaw20_13month_price=$(echo "$betaw20_closes" | tail -283 | head -1)
    
    if [ -n "$betaw20_price" ]; then
        echo "  🇵🇱 Beta ETF WIG20TR (BETAW20TR)"
        echo "     ISIN: PL0ETF000019"
        
        # Determine currency symbol
        if [ "$betaw20_currency" = "PLN" ]; then
            currency_symbol="zł"
        elif [ "$betaw20_currency" = "EUR" ]; then
            currency_symbol="€"
        elif [ "$betaw20_currency" = "USD" ]; then
            currency_symbol="$"
        else
            currency_symbol="$betaw20_currency"
        fi
        
        LC_NUMERIC=C printf "     Price: %.2f %s\n" "$betaw20_price" "$currency_symbol"
        
        if [ -n "$betaw20_prev_day" ] && [ "$betaw20_prev_day" != "null" ]; then
            prev_change=$(echo "scale=4; (($betaw20_price - $betaw20_prev_day) / $betaw20_prev_day) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Previous day: %.2f %s (%.2f%%)\n" "$betaw20_prev_day" "$currency_symbol" "$prev_change"
        fi
        if [ -n "$betaw20_week_price" ] && [ "$betaw20_week_price" != "null" ]; then
            week_change=$(echo "scale=4; (($betaw20_price - $betaw20_week_price) / $betaw20_week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Week ago: %.2f %s (%.2f%%)\n" "$betaw20_week_price" "$currency_symbol" "$week_change"
        fi
        if [ -n "$betaw20_2week_price" ] && [ "$betaw20_2week_price" != "null" ]; then
            week2_change=$(echo "scale=4; (($betaw20_price - $betaw20_2week_price) / $betaw20_2week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     2 weeks ago: %.2f %s (%.2f%%)\n" "$betaw20_2week_price" "$currency_symbol" "$week2_change"
        fi
        if [ -n "$betaw20_month_price" ] && [ "$betaw20_month_price" != "null" ]; then
            month_change=$(echo "scale=4; (($betaw20_price - $betaw20_month_price) / $betaw20_month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Month ago: %.2f %s (%.2f%%)\n" "$betaw20_month_price" "$currency_symbol" "$month_change"
        fi
        if [ -n "$betaw20_month_price" ] && [ "$betaw20_month_price" != "null" ] && [ -n "$betaw20_7month_price" ] && [ "$betaw20_7month_price" != "null" ]; then
            six_month_gain=$(echo "scale=4; (($betaw20_month_price - $betaw20_7month_price) / $betaw20_7month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     6-month gain (7m ago to 1m ago): %.2f%%\n" "$six_month_gain"
        fi
        if [ -n "$betaw20_month_price" ] && [ "$betaw20_month_price" != "null" ] && [ -n "$betaw20_13month_price" ] && [ "$betaw20_13month_price" != "null" ]; then
            year_gain=$(echo "scale=4; (($betaw20_month_price - $betaw20_13month_price) / $betaw20_13month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     12-month gain (13m ago to 1m ago): %.2f%%\n" "$year_gain"
        fi
    else
        echo "  ❌ BETAW20TR: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kurs BETAM40TR (Beta ETF mWIG40TR)
    sleep 1
    betam40_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/ETFBM40TR.WA?interval=1d&range=2y' 2>/dev/null)
    betam40_price=$(echo "$betam40_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    betam40_currency=$(echo "$betam40_response" | grep -o '"currency":"[A-Z]*"' | head -1 | cut -d'"' -f4)
    betam40_closes=$(echo "$betam40_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    betam40_prev_day=$(echo "$betam40_closes" | tail -2 | head -1)
    betam40_week_price=$(echo "$betam40_closes" | tail -7 | head -1)
    betam40_2week_price=$(echo "$betam40_closes" | tail -14 | head -1)
    betam40_month_price=$(echo "$betam40_closes" | tail -31 | head -1)
    betam40_7month_price=$(echo "$betam40_closes" | tail -157 | head -1)
    betam40_13month_price=$(echo "$betam40_closes" | tail -283 | head -1)
    
    if [ -n "$betam40_price" ]; then
        echo "  🇵🇱 Beta ETF mWIG40TR (BETAM40TR)"
        echo "     ISIN: PL0ETF000027"
        
        # Determine currency symbol
        if [ "$betam40_currency" = "PLN" ]; then
            currency_symbol="zł"
        elif [ "$betam40_currency" = "EUR" ]; then
            currency_symbol="€"
        elif [ "$betam40_currency" = "USD" ]; then
            currency_symbol="$"
        else
            currency_symbol="$betam40_currency"
        fi
        
        LC_NUMERIC=C printf "     Price: %.2f %s\n" "$betam40_price" "$currency_symbol"
        
        if [ -n "$betam40_prev_day" ] && [ "$betam40_prev_day" != "null" ]; then
            prev_change=$(echo "scale=4; (($betam40_price - $betam40_prev_day) / $betam40_prev_day) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Previous day: %.2f %s (%.2f%%)\n" "$betam40_prev_day" "$currency_symbol" "$prev_change"
        fi
        if [ -n "$betam40_week_price" ] && [ "$betam40_week_price" != "null" ]; then
            week_change=$(echo "scale=4; (($betam40_price - $betam40_week_price) / $betam40_week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Week ago: %.2f %s (%.2f%%)\n" "$betam40_week_price" "$currency_symbol" "$week_change"
        fi
        if [ -n "$betam40_2week_price" ] && [ "$betam40_2week_price" != "null" ]; then
            week2_change=$(echo "scale=4; (($betam40_price - $betam40_2week_price) / $betam40_2week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     2 weeks ago: %.2f %s (%.2f%%)\n" "$betam40_2week_price" "$currency_symbol" "$week2_change"
        fi
        if [ -n "$betam40_month_price" ] && [ "$betam40_month_price" != "null" ]; then
            month_change=$(echo "scale=4; (($betam40_price - $betam40_month_price) / $betam40_month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Month ago: %.2f %s (%.2f%%)\n" "$betam40_month_price" "$currency_symbol" "$month_change"
        fi
        if [ -n "$betam40_month_price" ] && [ "$betam40_month_price" != "null" ] && [ -n "$betam40_7month_price" ] && [ "$betam40_7month_price" != "null" ]; then
            six_month_gain=$(echo "scale=4; (($betam40_month_price - $betam40_7month_price) / $betam40_7month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     6-month gain (7m ago to 1m ago): %.2f%%\n" "$six_month_gain"
        fi
        if [ -n "$betam40_month_price" ] && [ "$betam40_month_price" != "null" ] && [ -n "$betam40_13month_price" ] && [ "$betam40_13month_price" != "null" ]; then
            year_gain=$(echo "scale=4; (($betam40_month_price - $betam40_13month_price) / $betam40_13month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     12-month gain (13m ago to 1m ago): %.2f%%\n" "$year_gain"
        fi
    else
        echo "  ❌ BETAM40TR: Error fetching data"
    fi
    
    echo ""
    
    # Pobierz kurs BETAS80TR (Beta ETF sWIG80TR)
    sleep 1
    betas80_response=$(curl -s -A "Mozilla/5.0" 'https://query1.finance.yahoo.com/v8/finance/chart/ETFBS80TR.WA?interval=1d&range=2y' 2>/dev/null)
    betas80_price=$(echo "$betas80_response" | grep -o '"regularMarketPrice":[0-9.]*' | head -1 | cut -d':' -f2)
    betas80_currency=$(echo "$betas80_response" | grep -o '"currency":"[A-Z]*"' | head -1 | cut -d'"' -f4)
    betas80_closes=$(echo "$betas80_response" | grep -o '"close":\[[^]]*\]' | sed 's/"close":\[//;s/\]//' | tr ',' '\n')
    betas80_prev_day=$(echo "$betas80_closes" | tail -2 | head -1)
    betas80_week_price=$(echo "$betas80_closes" | tail -7 | head -1)
    betas80_2week_price=$(echo "$betas80_closes" | tail -14 | head -1)
    betas80_month_price=$(echo "$betas80_closes" | tail -31 | head -1)
    betas80_7month_price=$(echo "$betas80_closes" | tail -157 | head -1)
    betas80_13month_price=$(echo "$betas80_closes" | tail -283 | head -1)
    
    if [ -n "$betas80_price" ]; then
        echo "  🇵🇱 Beta ETF sWIG80TR (BETAS80TR)"
        echo "     ISIN: PL0ETF000035"
        
        # Determine currency symbol
        if [ "$betas80_currency" = "PLN" ]; then
            currency_symbol="zł"
        elif [ "$betas80_currency" = "EUR" ]; then
            currency_symbol="€"
        elif [ "$betas80_currency" = "USD" ]; then
            currency_symbol="$"
        else
            currency_symbol="$betas80_currency"
        fi
        
        LC_NUMERIC=C printf "     Price: %.2f %s\n" "$betas80_price" "$currency_symbol"
        
        if [ -n "$betas80_prev_day" ] && [ "$betas80_prev_day" != "null" ]; then
            prev_change=$(echo "scale=4; (($betas80_price - $betas80_prev_day) / $betas80_prev_day) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Previous day: %.2f %s (%.2f%%)\n" "$betas80_prev_day" "$currency_symbol" "$prev_change"
        fi
        if [ -n "$betas80_week_price" ] && [ "$betas80_week_price" != "null" ]; then
            week_change=$(echo "scale=4; (($betas80_price - $betas80_week_price) / $betas80_week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Week ago: %.2f %s (%.2f%%)\n" "$betas80_week_price" "$currency_symbol" "$week_change"
        fi
        if [ -n "$betas80_2week_price" ] && [ "$betas80_2week_price" != "null" ]; then
            week2_change=$(echo "scale=4; (($betas80_price - $betas80_2week_price) / $betas80_2week_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     2 weeks ago: %.2f %s (%.2f%%)\n" "$betas80_2week_price" "$currency_symbol" "$week2_change"
        fi
        if [ -n "$betas80_month_price" ] && [ "$betas80_month_price" != "null" ]; then
            month_change=$(echo "scale=4; (($betas80_price - $betas80_month_price) / $betas80_month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     Month ago: %.2f %s (%.2f%%)\n" "$betas80_month_price" "$currency_symbol" "$month_change"
        fi
        if [ -n "$betas80_month_price" ] && [ "$betas80_month_price" != "null" ] && [ -n "$betas80_7month_price" ] && [ "$betas80_7month_price" != "null" ]; then
            six_month_gain=$(echo "scale=4; (($betas80_month_price - $betas80_7month_price) / $betas80_7month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     6-month gain (7m ago to 1m ago): %.2f%%\n" "$six_month_gain"
        fi
        if [ -n "$betas80_month_price" ] && [ "$betas80_month_price" != "null" ] && [ -n "$betas80_13month_price" ] && [ "$betas80_13month_price" != "null" ]; then
            year_gain=$(echo "scale=4; (($betas80_month_price - $betas80_13month_price) / $betas80_13month_price) * 100" | LC_NUMERIC=C bc)
            LC_NUMERIC=C printf "     12-month gain (13m ago to 1m ago): %.2f%%\n" "$year_gain"
        fi
    else
        echo "  ❌ BETAS80TR: Error fetching data"
    fi
    
    echo ""
    echo "  Updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Press Ctrl+C to exit"
    echo ""
    echo "  Next update in 30 minutes..."
    
    # Czekaj 30 minut przed następnym odświeżeniem
    sleep 1800
done
