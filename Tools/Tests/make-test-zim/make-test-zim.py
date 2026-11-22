#!/usr/bin/env python3
"""Synthetic ZIM archives for Ask retrieval and answer-index tests. No downloads, no real content.

usage: make-test-zim.py <out folder> [--small-only] [--big N]
  practical.zim     ~300 health, repair and food articles with sections and a full-text index
  encyclopedia.zim  ~20,000 short encyclopedia-style articles (lead + one section), also indexed;
                    the practical topics appear here too, shorter, so both archives answer the same questions
  --big N           only big.zim: N Wikipedia-sized stubs (a lead of 40 to 220 words, two or three sections) over
                    a Zipf-distributed vocabulary of 60,000 made-up words plus everyday English, no full-text index.
                    For answer-index scale tests (300,000 articles: about 4 minutes and 0.5 GB).

Builds the zimwrite helper (Objective-C++ against Vendor/CoreKiwix.xcframework) when it isn't there yet.
"""
import os
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parents[2]

# --- Seed topics: hand-written facts, one list per section. Variants below recombine them. ---------------

HEALTH = {
    "Heat stroke": {
        "lead": ["Heat stroke is the most serious heat-related illness, a medical emergency in which the body's temperature rises above 40 °C (104 °F) and its cooling system fails.",
                 "It often follows heat exhaustion during hard work or exercise in hot, humid weather, and it can damage the brain, heart and kidneys within hours.",
                 "Older adults, young children, people with heart disease and anyone taking diuretics are at higher risk."],
        "Signs and symptoms": ["Confusion, slurred speech or strange behavior are the key warning signs.",
                               "The skin may be hot and dry, although people who were exercising can still be sweating.",
                               "A fast, strong pulse, a throbbing headache, nausea and fainting are common.",
                               "Seizures and loss of consciousness can follow if the person is not cooled quickly."],
        "Treatment": ["Call emergency services, then start cooling the person at once; every minute counts.",
                      "Move them into shade or air conditioning and remove extra clothing.",
                      "Cold-water immersion up to the neck is the fastest way to bring the temperature down.",
                      "If a tub is not available, soak them with cool water and fan them, and put ice packs in the armpits, groin and neck.",
                      "Do not give fever medicines such as acetaminophen or aspirin; they do not help and may cause harm.",
                      "Keep cooling until the temperature falls to about 39 °C (102 °F) or help arrives."],
        "Prevention": ["Drink water regularly in hot weather before you feel thirsty.",
                       "Schedule heavy work for early morning or evening and rest in the shade.",
                       "Wear light, loose clothing and a wide-brimmed hat, and never leave anyone in a parked car."],
    },
    "Heat exhaustion": {
        "lead": ["Heat exhaustion is a heat-related illness caused by losing too much water and salt through sweating.",
                 "It is less severe than heat stroke but can progress to it if the person keeps working in the heat."],
        "Signs and symptoms": ["Heavy sweating, cool and clammy skin, muscle cramps, weakness and dizziness are typical.",
                               "The pulse is fast and weak, and nausea or a headache are common.",
                               "Unlike heat stroke, the person usually remains alert and able to answer questions."],
        "Treatment": ["Move the person to a cool place and have them lie down with their legs raised.",
                      "Loosen tight clothing and apply cool, wet cloths to the skin.",
                      "Give sips of water or an oral rehydration drink if they are fully awake and not vomiting.",
                      "Get medical help if symptoms worsen or last longer than an hour, or if confusion develops."],
    },
    "Burns": {
        "lead": ["A burn is damage to the skin and deeper tissues caused by heat, chemicals, electricity, sunlight or radiation.",
                 "Scalds from hot liquids such as boiling water are among the most common burns at home, especially in children.",
                 "Burns are classed by depth as superficial (first-degree), partial-thickness (second-degree) or full-thickness (third-degree)."],
        "First aid": ["Stop the burning: move away from the source and remove clothing or jewelry near the burn unless it is stuck to the skin.",
                      "Cool the burn under cool running water for 20 minutes as soon as possible; this reduces pain and depth.",
                      "Do not use ice, butter, toothpaste or oils, which can damage tissue further.",
                      "Cover the burn loosely with plastic cling film or a clean, non-fluffy cloth.",
                      "Keep the person warm, because cooling large burns can cause hypothermia."],
        "When to get help": ["Get emergency care for burns larger than the person's palm, deep burns, or burns on the face, hands, feet, genitals or joints.",
                             "Electrical and chemical burns always need medical assessment, even when the skin looks only slightly damaged.",
                             "Blisters that are large, a burn that becomes red and swollen days later, or fever can mean infection."],
        "Healing": ["Superficial burns usually heal in about a week without scarring.",
                    "Partial-thickness burns form blisters and may take two to three weeks to heal; leave blisters intact when possible.",
                    "Full-thickness burns destroy nerve endings, so they may be painless, and they often need skin grafts."],
    },
    "Nosebleed": {
        "lead": ["A nosebleed, or epistaxis, is bleeding from the blood vessels inside the nose.",
                 "Most nosebleeds come from the front of the nasal septum and stop with simple pressure."],
        "First aid": ["Sit upright and lean slightly forward so blood drains out of the nose rather than down the throat.",
                      "Pinch the soft part of the nose, just below the bony bridge, firmly for 10 to 15 minutes without letting go to check.",
                      "Breathe through the mouth and spit out any blood instead of swallowing it.",
                      "A cold pack on the bridge of the nose may help; do not tilt the head back or lie flat."],
        "When to get help": ["Seek care if bleeding lasts longer than 20 minutes of steady pressure, follows a blow to the head, or is very heavy.",
                             "Frequent nosebleeds, or bleeding in someone taking blood thinners, should be checked by a clinician."],
        "Prevention": ["Dry indoor air is a common cause; a humidifier or saline spray keeps the lining moist.",
                       "Avoid picking the nose and blowing it hard for a day after a bleed."],
    },
    "Dehydration": {
        "lead": ["Dehydration happens when the body loses more water and salts than it takes in, through sweating, vomiting, diarrhea or fever.",
                 "Babies, young children and older adults become dehydrated faster and show it in different ways."],
        "Signs and symptoms": ["Thirst, dark yellow urine, urinating less often and a dry mouth are early signs.",
                               "In infants, look for fewer wet diapers, no tears when crying, a sunken soft spot on the head and unusual sleepiness.",
                               "Dizziness, a rapid heartbeat, confusion and cold hands and feet suggest severe dehydration."],
        "Treatment": ["Oral rehydration solution replaces both water and salts and is better than plain water for diarrhea.",
                      "Give small, frequent sips: a teaspoon every minute or two for a child who is vomiting.",
                      "A homemade solution can be made from one liter of clean water, six level teaspoons of sugar and half a level teaspoon of salt.",
                      "Keep breastfeeding infants, and offer the solution between feeds."],
        "When to get help": ["Get urgent care for a baby with no wet diaper in six hours, for bloody diarrhea, or for anyone who is very drowsy or cannot keep fluids down."],
    },
    "Sprained ankle": {
        "lead": ["A sprained ankle is a stretch or tear of the ligaments that hold the ankle bones together, usually from rolling the foot inward.",
                 "Most sprains heal with rest and gradual exercise over two to six weeks."],
        "Treatment": ["Rest the ankle and avoid putting weight on it for the first day or two if it is painful.",
                      "Apply a cold pack wrapped in a cloth for 15 to 20 minutes every two to three hours during the first two days.",
                      "Compress the ankle with an elastic bandage, snug but not tight enough to cause numbness.",
                      "Elevate the foot above the level of the heart as much as possible to reduce swelling.",
                      "Pain relievers such as ibuprofen or acetaminophen can help; follow the package directions."],
        "Recovery": ["Start gentle range-of-motion exercises, such as tracing the alphabet with the toes, once the pain allows.",
                     "Balance exercises on one foot help prevent the ankle from giving way again."],
        "When to get help": ["Seek care if you cannot take four steps, if there is tenderness over the ankle bones, or if the foot is numb, cold or misshapen; these can mean a fracture."],
    },
    "Hypothermia": {
        "lead": ["Hypothermia is a dangerous drop in body temperature below 35 °C (95 °F), when the body loses heat faster than it can make it.",
                 "It can happen in cold water within minutes, and in cool, wet, windy weather even above freezing."],
        "Signs and symptoms": ["Shivering, clumsy hands, slurred speech and confusion are early signs.",
                               "As it worsens, shivering stops, the person becomes drowsy, and breathing and pulse slow."],
        "Treatment": ["Call emergency services, then move the person out of the cold and wind, handling them gently.",
                      "Replace wet clothing with dry layers and wrap them in blankets, including the head, leaving the face clear.",
                      "Warm the center of the body first: chest, neck, head and groin, using skin-to-skin contact or warm, dry compresses.",
                      "Give warm, sweet drinks only if the person is alert and can swallow; never give alcohol.",
                      "Do not rub the arms and legs or use hot water, which can trigger dangerous heart rhythms."],
        "Prevention": ["Dress in layers, keep dry, cover the head and hands, and carry extra clothing outdoors."],
    },
    "Carbon monoxide poisoning": {
        "lead": ["Carbon monoxide (CO) is a colorless, odorless gas produced when fuel burns, and breathing it prevents blood from carrying oxygen.",
                 "Poisoning often happens during power outages when generators, grills or heaters are used indoors or in garages."],
        "Signs and symptoms": ["Headache, dizziness, weakness, nausea, vomiting, chest pain and confusion are the most common symptoms.",
                               "Symptoms are often described as flu-like, and several people or pets in the same home may feel ill at once.",
                               "People who are asleep or drunk can die before they notice any symptoms."],
        "What to do": ["Get everyone into fresh air immediately and call emergency services from outside.",
                       "Do not go back inside until the fire service says it is safe.",
                       "Anyone with symptoms needs medical care; oxygen treatment may be needed."],
        "Prevention": ["Never run a generator, grill, camp stove or charcoal burner inside a home, basement, garage or tent, even with windows open.",
                       "Keep generators at least 6 meters (20 feet) from doors, windows and vents.",
                       "Install battery-powered CO alarms on every floor and near sleeping areas, and test them monthly."],
    },
    "Choking": {
        "lead": ["Choking happens when food or an object blocks the airway, so air cannot reach the lungs.",
                 "A person who cannot cough, speak or breathe needs help at once."],
        "First aid for adults": ["Encourage them to keep coughing if they can.",
                                 "If they cannot, give up to five firm back blows between the shoulder blades with the heel of your hand.",
                                 "Then give up to five abdominal thrusts: stand behind them, make a fist above the navel and pull sharply inward and upward.",
                                 "Alternate back blows and thrusts and call emergency services if the blockage does not clear."],
        "Infants": ["For a baby under one year, give back blows with the baby face-down along your forearm, then chest thrusts with two fingers.",
                    "Never give abdominal thrusts to an infant."],
    },
    "Fever in children": {
        "lead": ["A fever is a body temperature of 38 °C (100.4 °F) or higher and is usually the body's response to an infection.",
                 "Most fevers in children are caused by viral illnesses and go away in a few days."],
        "Care at home": ["Offer plenty of fluids and let the child rest; dress them lightly.",
                         "Acetaminophen or ibuprofen can make a child more comfortable; dose by weight using the product's directions.",
                         "Never give aspirin to children or teenagers because of the risk of Reye's syndrome."],
        "When to get help": ["Any fever in a baby younger than three months needs prompt medical care.",
                             "Get help for a stiff neck, a rash that does not fade when pressed, trouble breathing, signs of dehydration or a seizure."],
    },
    "Cuts and wounds": {
        "lead": ["Most small cuts and scrapes can be treated at home by stopping the bleeding, cleaning the wound and keeping it covered.",
                 "Deep wounds, wounds that gape open and wounds from dirty or rusty objects may need medical care."],
        "Stopping bleeding": ["Press firmly on the wound with a clean cloth or bandage for at least ten minutes without lifting it.",
                              "Raise the injured part above the heart if possible.",
                              "For severe bleeding from a limb that pressure cannot control, a tourniquet placed above the wound can save a life."],
        "Cleaning": ["Rinse the wound under clean running water and wash around it with soap.",
                     "Remove dirt with tweezers cleaned in alcohol; do not use hydrogen peroxide or iodine inside the wound.",
                     "Cover it with a sterile dressing and change it daily or when it becomes wet or dirty."],
        "Infection": ["Increasing redness, warmth, swelling, pus or red streaks spreading from the wound are signs of infection.",
                      "A tetanus booster may be needed if the last one was more than five years ago for a dirty wound."],
    },
    "Bee and wasp stings": {
        "lead": ["Stings from bees, wasps and hornets usually cause brief pain, redness and swelling at the site.",
                 "A small number of people have a severe allergic reaction, anaphylaxis, which is life-threatening."],
        "First aid": ["Scrape a bee's stinger out sideways with a fingernail or card as soon as possible.",
                      "Wash the area and apply a cold pack to reduce swelling.",
                      "An antihistamine and a pain reliever can ease itching and pain."],
        "Anaphylaxis": ["Trouble breathing, swelling of the lips or throat, hives spreading over the body, dizziness or fainting are signs of anaphylaxis.",
                        "Use an epinephrine auto-injector if the person has one and call emergency services immediately."],
    },
    "Diarrhea": {
        "lead": ["Diarrhea is loose, watery stools three or more times a day, most often caused by infections from contaminated food or water.",
                 "The main danger is dehydration, especially in young children and older adults."],
        "Treatment": ["Drink oral rehydration solution or clear fluids to replace lost water and salts.",
                      "Keep eating small amounts of normal food; there is no need to stop eating.",
                      "Wash hands with soap after using the toilet and before preparing food to avoid spreading infection."],
        "When to get help": ["Get care for blood in the stool, high fever, signs of dehydration or diarrhea lasting more than two days in an adult."],
    },
    "Frostbite": {
        "lead": ["Frostbite is freezing of the skin and the tissue beneath it, most often on the fingers, toes, nose, ears and cheeks."],
        "Signs": ["Skin first turns red and painful, then white or grayish-yellow, hard and numb."],
        "Treatment": ["Get out of the cold and remove wet clothing and anything tight such as rings.",
                      "Rewarm the area in warm, not hot, water at 37 to 39 °C (99 to 102 °F) for 15 to 30 minutes.",
                      "Do not rub the skin or rewarm it if there is a chance it will freeze again.",
                      "Seek medical care for anything beyond mild frostnip."],
    },
    "Allergic reactions": {
        "lead": ["An allergic reaction is the immune system overreacting to a harmless substance such as pollen, food, medicine or insect venom."],
        "Mild reactions": ["Sneezing, an itchy rash, hives and watery eyes can be treated with an antihistamine."],
        "Severe reactions": ["Anaphylaxis causes trouble breathing, throat swelling, vomiting and a drop in blood pressure within minutes.",
                             "Inject epinephrine into the outer thigh at once and call emergency services; a second dose may be needed after five to fifteen minutes."],
    },
    "Poisoning": {
        "lead": ["Poisoning happens when someone swallows, breathes in or touches a harmful substance such as medicines, cleaning products or plants."],
        "What to do": ["Call Poison Help or emergency services right away, even if the person seems fine.",
                       "Do not make the person vomit unless a poison expert tells you to.",
                       "Keep the container or label so you can tell responders exactly what was taken."],
    },
}

REPAIR = {
    "Leaking faucet": {
        "lead": ["A dripping faucet usually means a worn washer, O-ring or cartridge inside the handle, and it can waste thousands of liters of water a year.",
                 "Most faucet repairs need only a screwdriver, an adjustable wrench and the right replacement part."],
        "Before you start": ["Turn off the water supply valves under the sink and open the faucet to drain the line.",
                             "Plug the drain with a rag so small screws cannot fall in.",
                             "Identify the faucet type: compression faucets have two handles and rubber washers; cartridge, ball and ceramic-disc faucets usually have one."],
        "Repair steps": ["Pry off the decorative cap, remove the handle screw and lift off the handle.",
                         "Unscrew the packing nut or retaining clip and pull out the stem or cartridge.",
                         "For a compression faucet, replace the seat washer and O-ring with exact matches.",
                         "For a cartridge faucet, take the old cartridge to the store to buy an identical one.",
                         "Reassemble the faucet, turn the water back on slowly and check for drips."],
    },
    "Circuit breaker": {
        "lead": ["A circuit breaker is a switch in the electrical panel that automatically turns off power to a circuit when it is overloaded or shorted.",
                 "A tripped breaker sits in the middle or off position and must be reset by hand."],
        "Resetting a breaker": ["Unplug or switch off the devices on the dead circuit first.",
                                "Open the panel door and find the breaker whose handle is out of line with the others.",
                                "Push the handle firmly to the off position, then back to on.",
                                "If it trips again right away, leave it off: there is a short circuit or fault that an electrician should find."],
        "Why breakers trip": ["Too many high-power appliances such as heaters, kettles and microwaves on one circuit cause overloads.",
                              "A damaged cord, loose wire or water in an outlet can cause a short circuit or ground fault.",
                              "GFCI outlets in kitchens and bathrooms have their own test and reset buttons."],
        "Safety": ["Stand on a dry surface and use one hand when working at the panel.",
                   "Never remove the panel cover; the parts behind it stay live even with the main breaker off."],
    },
    "Clogged drain": {
        "lead": ["Kitchen sink drains clog with grease and food scraps, while bathroom drains clog with hair and soap scum.",
                 "Most clogs can be cleared without chemical drain cleaners, which can damage pipes and burn skin."],
        "Methods": ["Pour a kettle of hot, not boiling, water down the drain to soften grease.",
                    "Use a cup plunger over the drain, covering any overflow hole with a wet cloth, and plunge firmly a dozen times.",
                    "Pour half a cup of baking soda followed by a cup of vinegar, wait 15 minutes, then flush with hot water.",
                    "Remove and clean the U-shaped trap under the sink with a bucket underneath.",
                    "Feed a drain snake or auger into the pipe and turn it to break up or pull out the clog."],
        "Prevention": ["Wipe greasy pans with paper before washing and use a strainer to catch hair and food."],
    },
    "Drywall repair": {
        "lead": ["Drywall, also called plasterboard or gypsum board, is easy to patch once you match the repair to the size of the hole."],
        "Small holes": ["Nail holes and small dents need only a thin coat of spackle applied with a putty knife, sanded smooth when dry."],
        "Medium holes": ["Holes up to about 15 centimeters can be covered with a self-adhesive mesh patch.",
                         "Spread joint compound over the patch in two or three thin coats, feathering the edges wider each time.",
                         "Let each coat dry completely, sand lightly, then prime and paint."],
        "Large holes": ["Cut the damaged area into a neat rectangle and screw wood backing strips inside the opening.",
                        "Screw in a piece of new drywall of the same thickness, then tape and finish the seams with joint compound."],
    },
    "Generator safety": {
        "lead": ["Portable generators provide backup power during outages but cause carbon monoxide poisoning, fires and electrocution when used incorrectly."],
        "Placement": ["Run the generator outdoors only, at least 6 meters (20 feet) from the house, with the exhaust pointed away from doors and windows.",
                      "Keep it dry under an open canopy; never run it in a garage, basement or porch."],
        "Connecting appliances": ["Plug appliances directly into the generator with heavy-duty outdoor extension cords.",
                                  "Never plug a generator into a wall outlet; this backfeeds the power lines and can kill utility workers.",
                                  "A licensed electrician can install a transfer switch to power household circuits safely."],
        "Fuel": ["Turn the generator off and let it cool before refueling.",
                 "Store gasoline in approved containers away from living areas and add stabilizer for long-term storage."],
    },
    "Frozen pipes": {
        "lead": ["Water expands when it freezes, so pipes in unheated spaces can burst in cold weather and flood a home when they thaw."],
        "Thawing": ["Open the faucet so melting water can flow out.",
                    "Warm the frozen section with a hair dryer, heating pad or towels soaked in hot water, starting near the faucet.",
                    "Never use an open flame or torch to thaw pipes."],
        "Prevention": ["Let faucets drip during extreme cold, open cabinet doors under sinks and insulate pipes in crawl spaces."],
    },
    "Flat tire": {
        "lead": ["Changing a flat tire requires a jack, a lug wrench and an inflated spare, and takes about 20 minutes."],
        "Steps": ["Park on flat, firm ground away from traffic, turn on the hazard lights and set the parking brake.",
                  "Loosen the lug nuts half a turn while the wheel is still on the ground.",
                  "Raise the car with the jack at the frame point shown in the owner's manual.",
                  "Remove the nuts and the wheel, fit the spare and tighten the nuts by hand in a star pattern.",
                  "Lower the car and tighten the nuts fully, then check the spare's pressure as soon as you can."],
    },
    "Toilet repair": {
        "lead": ["A running toilet usually has a worn flapper or a fill valve set too high, and both are cheap to replace."],
        "Fixing a running toilet": ["Lift the tank lid and check whether water is flowing into the overflow tube; if so, lower the float.",
                                    "If the tank slowly empties, the flapper is leaking: turn off the water, flush, and replace the flapper.",
                                    "A few drops of food coloring in the tank show a leak if color appears in the bowl without flushing."],
    },
    "Roof leak": {
        "lead": ["Roof leaks most often start at damaged shingles, flashing around chimneys and vents, or clogged gutters."],
        "Temporary repair": ["Catch dripping water with buckets and puncture a bulging ceiling to drain it in a controlled spot.",
                             "From the attic, trace the water stain uphill to find the entry point.",
                             "Cover the damaged area outside with a heavy plastic tarp, nailed to battens and extended over the ridge."],
    },
}

FOOD = {
    "Food safety during a power outage": {
        "lead": ["During a power outage a closed refrigerator keeps food cold for about 4 hours, and a full freezer holds its temperature for about 48 hours (24 if half full).",
                 "Perishable food that has been above 4 °C (40 °F) for more than 2 hours should be thrown away."],
        "Refrigerator": ["Keep the doors closed as much as possible and put an appliance thermometer inside.",
                         "Throw out meat, poultry, fish, eggs, soft cheeses, milk and leftovers after 4 hours without power.",
                         "Hard cheeses, butter, fruit, raw vegetables and condiments such as ketchup and mustard are usually safe."],
        "Freezer": ["Food that still has ice crystals or is at 4 °C (40 °F) or below can be safely refrozen.",
                    "Group frozen items together and add bags of ice or dry ice to make them last longer."],
        "When in doubt": ["Never taste food to decide whether it is safe; when in doubt, throw it out."],
    },
    "Water purification": {
        "lead": ["Water from streams, rain barrels or floods can carry bacteria, viruses and parasites, so it must be treated before drinking.",
                 "Boiling is the most reliable method and works without electricity on a stove, grill or fire."],
        "Boiling": ["Bring clear water to a rolling boil for one minute, or three minutes above 2,000 meters (6,500 feet) elevation.",
                    "Let it cool and store it in clean, covered containers."],
        "Chemical disinfection": ["Unscented household bleach (5 to 9 percent sodium hypochlorite) can disinfect water: add 8 drops per 4 liters (1 gallon), stir and wait 30 minutes.",
                                  "The water should smell slightly of chlorine; if not, repeat the dose and wait another 15 minutes.",
                                  "Chlorine dioxide tablets and iodine also work; follow the package directions."],
        "Filtering": ["Filter cloudy water through a clean cloth or coffee filter, or let it settle, before disinfecting.",
                      "Portable filters remove bacteria and parasites but most do not remove viruses unless combined with disinfection.",
                      "Solar disinfection works by leaving clear water in plastic bottles in full sunlight for six hours."],
    },
    "Canning tomatoes": {
        "lead": ["Tomatoes can be preserved at home by water-bath canning, provided acid is added, because many varieties are not acidic enough on their own."],
        "Preparing": ["Wash jars and lids in hot soapy water and keep the jars hot until filling.",
                      "Blanch tomatoes in boiling water for 30 to 60 seconds, then plunge them in cold water to slip off the skins.",
                      "Add 2 tablespoons of bottled lemon juice or half a teaspoon of citric acid to each liter jar."],
        "Processing": ["Pack the tomatoes, leaving 1.25 centimeters (half an inch) of headspace, remove air bubbles and wipe the rims.",
                       "Process liter jars in a boiling water bath for about 85 minutes for whole tomatoes, adjusting for altitude.",
                       "Let the jars cool for 12 to 24 hours and check that each lid has sealed and does not flex."],
        "Safety": ["Discard any jar with a bulging lid, leaking seal, spurting liquid or bad smell; it may contain botulism toxin."],
    },
    "Long-term rice storage": {
        "lead": ["White rice stored airtight in a cool, dry, dark place can last 25 years or more, while brown rice keeps only about six months because of its oils."],
        "Containers": ["Food-grade buckets with gamma lids, Mylar bags and glass jars keep out moisture, insects and rodents.",
                       "Oxygen absorbers sealed in with the rice prevent insect eggs from hatching and slow staling."],
        "Conditions": ["Keep storage below 21 °C (70 °F); every 10 degrees warmer roughly halves the shelf life.",
                       "Freeze newly bought rice for three days to kill any insects before packing."],
    },
    "Bread without yeast": {
        "lead": ["Quick breads such as soda bread, flatbreads and bannock rise with baking soda or baking powder instead of yeast, so they need no proving time."],
        "Soda bread": ["Mix 500 grams of flour, one teaspoon of baking soda and one teaspoon of salt, then stir in about 400 milliliters of buttermilk.",
                       "Shape a round loaf, cut a deep cross on top and bake at 200 °C (400 °F) for about 40 minutes.",
                       "Milk soured with a tablespoon of lemon juice or vinegar can replace buttermilk."],
        "Flatbread": ["A simple flatbread needs only flour, water, salt and a little oil, cooked in a dry pan or on a griddle over a fire."],
    },
    "Emergency food supply": {
        "lead": ["An emergency food supply should hold at least three days of food that needs no refrigeration and little or no cooking, and ideally two weeks."],
        "What to store": ["Canned meats, fish, beans, fruit and vegetables, peanut butter, crackers, dried fruit and nuts store well.",
                          "Include foods for babies, older adults and pets, and a manual can opener."],
        "Rotation": ["Write purchase dates on cans and use the oldest first, replacing them as you go."],
    },
    "Food poisoning": {
        "lead": ["Food poisoning is illness caused by eating food contaminated with bacteria, viruses, parasites or their toxins."],
        "Symptoms": ["Nausea, vomiting, diarrhea and stomach cramps usually start within hours to a few days of eating the food."],
        "Prevention": ["Cook meat to safe internal temperatures, keep raw meat away from ready-to-eat foods and refrigerate leftovers within two hours."],
    },
}

CONTEXTS = {
    "health": ["in children", "in older adults", "outdoors", "while camping", "during a heat wave", "at work", "without medical help nearby", "after a disaster", "for caregivers"],
    "repair": ["in an older house", "in an apartment", "without power tools", "in winter", "on a budget", "for beginners", "after a storm", "with basic tools"],
    "food": ["without power", "in a small kitchen", "for a large family", "while camping", "in hot weather", "on a budget", "after a flood", "for beginners"],
}

CONTEXT_NOTES = {
    "in children": ["Children have less body reserve than adults, so problems develop faster and need closer watching.",
                    "Doses of any medicine must be based on the child's weight, not age alone."],
    "in older adults": ["Older adults may not notice symptoms such as thirst or pain as clearly, and they often take medicines that change how the body responds.",
                        "Check on older neighbors and relatives regularly during emergencies."],
    "outdoors": ["Far from home, plan for slower help: carry a first aid kit, water and a way to call for help."],
    "while camping": ["At a campsite, keep supplies dry and organized so they can be found quickly in the dark.",
                      "Tell someone your route and expected return time before leaving."],
    "during a heat wave": ["During a heat wave, the risks rise for everyone; drink regularly and check on vulnerable people twice a day."],
    "at work": ["Employers should provide water, rest breaks and shade, and workers should watch each other for warning signs."],
    "without medical help nearby": ["When help is hours away, record what happened, the time and the person's condition, and keep reassessing every few minutes."],
    "in an older house": ["Older houses may have galvanized pipes, fuses instead of breakers, or lead paint; test before sanding old paint."],
    "in an apartment": ["In an apartment, check the lease and tell the building manager before repairs that affect shared pipes or wiring."],
    "without power tools": ["Hand tools take longer but give good results; a sharp utility knife and a hand saw cover most jobs."],
    "in winter": ["In winter, keep the work area warm so materials such as caulk and joint compound cure properly."],
    "on a budget": ["Buying only the worn part, rather than a whole new fixture, keeps the cost of most repairs low."],
    "for beginners": ["Take photos at each step of disassembly so you can put everything back in the right order."],
    "without power": ["Without power, a camp stove or grill used outdoors can cook and boil water; never use them indoors."],
    "in a small kitchen": ["In a small kitchen, prepare and clean as you go so raw and cooked foods never share a surface."],
    "for a large family": ["For a large family, scale quantities up and label containers clearly with contents and dates."],
    "after a disaster": ["After a disaster, clinics may be closed or overwhelmed; follow official instructions on where to get care."],
    "for caregivers": ["Caregivers should look after their own rest and hydration too, and keep a written list of the person's medicines."],
    "after a storm": ["After a storm, check for downed power lines and gas smells before starting any repair, and photograph damage for insurance."],
    "with basic tools": ["A basic kit of screwdrivers, pliers, an adjustable wrench, a tape measure and a utility knife handles most of these jobs."],
    "after a flood": ["After a flood, throw away any food that touched floodwater, including canned goods with damaged seams."],
    "in hot weather": ["In hot weather, food spoils faster; keep perishables at or below 4 °C (40 °F) and never leave them out for more than one hour above 32 °C (90 °F)."],
}

FILLER = [
    "Practice the steps before you need them, so they come naturally under stress.",
    "Keep a printed copy of these instructions with your emergency supplies.",
    "Local regulations and building codes may set additional requirements.",
    "Write down what you did and when, which helps anyone who takes over later.",
    "Work slowly and check each step, especially when you are tired or the light is poor.",
    "Ask a neighbor or friend for help if the job needs more than two hands.",
]

NOISE = ('<nav><a href="Main_Page">Main page</a> | <a href="Random">Random article</a></nav>'
         '<table class="infobox"><tr><td>Category</td><td>{cat}</td></tr></table>')


def slug(title):
    return title.replace(" ", "_").replace("'", "").replace(",", "")


def paragraphize(sentences, rng, extra=()):
    s = list(sentences)
    if extra:
        s.insert(rng.randrange(len(s) + 1), rng.choice(list(extra)))
    return linkify(" ".join(s), rng)


def linkify(text, rng):
    """Wikipedia-style markup weight: links on some words and spans around others, so the HTML is as heavy as
    a real article's and stripping it costs what it does in practice."""
    words = text.split(" ")
    for i, w in enumerate(words):
        if len(w) > 5 and w.isalpha() and rng.random() < 0.18:
            words[i] = f'<a href="./{w.capitalize()}" title="{w.capitalize()}" class="mw-link" rel="mw:WikiLink">{w}</a>'
        elif rng.random() < 0.04:
            words[i] = f'<span class="mw-ref" id="cite_ref-{rng.randint(1, 999)}"><a href="#cite_note-{rng.randint(1, 99)}">{w}</a></span>'
    return " ".join(words)


def navbox(rng, cat):
    links = "".join(f'<li><a href="./{stub_title(rng)}" title="{stub_title(rng)}">{stub_title(rng)}</a></li>' for _ in range(160))
    return f'<table class="navbox" role="presentation"><tr><th>{cat.capitalize()} topics</th></tr><tr><td><ul>{links}</ul></td></tr></table>'


def references(rng, n):
    items = "".join(
        f'<li id="cite_note-{i}"><span class="mw-cite-backlink"><a href="#cite_ref-{i}">^</a></span> '
        f'<span class="reference-text"><cite class="citation book">{stub_title(rng)}, {stub_title(rng)} ({rng.randint(1950, 2025)}). '
        f'<i>{stub_title(rng)} handbook of {rng.choice(["field care", "home repair", "food storage", "safety"])}</i>. '
        f'{stub_title(rng)} Press. pp. {rng.randint(1, 400)}&ndash;{rng.randint(401, 800)}.</cite></span></li>' for i in range(n))
    return f'<h2>References</h2><div class="reflist"><ol class="references">{items}</ol></div>'


def article_html(title, cat, sections, rng, context=None, short=False):
    parts = [f"<html><head><title>{title}</title><style>body{{font-family:serif}}</style></head><body>",
             NOISE.format(cat=cat), f"<h1>{title}</h1>"]
    lead = list(sections["lead"])
    if context:
        lead.append(f"This article covers {sections['_base'].lower()} {context}.")
        lead += CONTEXT_NOTES.get(context, [])[:1]
    parts.append(f"<p>{paragraphize(lead, rng)}<sup>[1]</sup></p>")
    heads = [k for k in sections if not k.startswith("_") and k != "lead"]
    if short:
        heads = heads[:1]
    for h in heads:
        sentences = list(sections[h])
        parts.append(f"<h2>{h}</h2>")
        if len(sentences) > 4 and not short:
            half = len(sentences) // 2
            parts.append(f"<p>{paragraphize(sentences[:half], rng)}</p>")
            parts.append(f"<p>{paragraphize(sentences[half:], rng, FILLER)}</p>")
        else:
            parts.append(f"<p>{paragraphize(sentences, rng, FILLER if not short else ())}</p>")
    if context and not short and CONTEXT_NOTES.get(context):
        parts.append(f"<h2>{context.capitalize()}</h2><p>{' '.join(CONTEXT_NOTES[context])} {rng.choice(FILLER)}</p>")
    if short:
        parts.append(references(rng, 6))
    else:
        parts.append(references(rng, 60) + navbox(rng, cat) + navbox(rng, cat))
    parts.append('</body></html>')
    return "".join(parts)


def practical_articles(rng):
    out = []
    for cat, seeds in (("health", HEALTH), ("repair", REPAIR), ("food", FOOD)):
        for title, sections in seeds.items():
            sec = dict(sections); sec["_base"] = title
            out.append((slug(title), title, cat, sec, None))
            # Context variants make the archive bigger and repetitive in places, like real references.
            n = {"health": 9, "repair": 8, "food": 8}[cat]
            for context in rng.sample(CONTEXTS[cat], k=min(n, len(CONTEXTS[cat]))):
                t = f"{title} {context}"
                out.append((slug(t), t, cat, sec, context))
    return out


# --- Encyclopedia stubs ------------------------------------------------------------------------------------

SYL = ["al", "ber", "cor", "dun", "el", "fen", "gar", "hal", "ist", "jor", "kel", "lin", "mar", "nor", "or", "pel",
       "quin", "ros", "sal", "tor", "ul", "ven", "wil", "yar", "zan", "bro", "cal", "dra", "esk", "for"]
KINDS = [
    ("river", "is a river in the {region} region, about {n} kilometers long, that flows into the {other} estuary.",
     ["Its basin supplies drinking water to several towns, and spring floods have damaged farmland along its banks.",
      "Mills once used its current for power, and the old water wheels are now preserved as a heritage site.",
      "The river freezes in hard winters, when local people cross it on foot."]),
    ("village", "is a village in the {region} region with a population of about {n} hundred people.",
     ["The village grew around a market and a stone bridge built in the eighteenth century.",
      "Its economy depends on farming, food processing and a small hardware factory.",
      "Heavy storms in the last decade caused long power outages and led to a community emergency plan."]),
    ("plant", "is a flowering plant species native to the {region} region, growing to about {n} centimeters tall.",
     ["Its leaves were used in folk medicine to treat burns and fevers, although there is no good evidence that this works.",
      "The seeds are edible after cooking, and the plant tolerates heat and drought.",
      "It is sometimes confused with a toxic relative, which causes stomach pain and vomiting if eaten."]),
    ("ship", "was a cargo ship launched in {n}0 that carried grain and machinery along the {region} coast.",
     ["She was lost in a winter storm after her engine room flooded and the crew abandoned ship.",
      "Survivors spent two days in lifeboats, and several were treated for hypothermia and frostbite.",
      "The wreck now lies in shallow water and is a popular dive site."]),
    ("engineer", "was an engineer from the {region} region, born in {n}12, known for work on water supply and electrical systems.",
     ["He designed one of the first public water filtration plants, which reduced outbreaks of cholera and diarrhea.",
      "Later he worked on circuit protection for factories, an early form of the modern circuit breaker.",
      "His notebooks on plumbing and drainage were published after his death."]),
    ("dish", "is a traditional dish from the {region} region made from rice, beans and about {n} spices.",
     ["It is cooked slowly in a clay pot and was originally prepared for harvest festivals.",
      "Leftovers keep for a day in a cool place, and the dish is often reheated with extra water.",
      "Variations use bread instead of rice, or add preserved tomatoes and dried fish."]),
]
REGIONS = ["Northern", "Eastern", "Coastal", "Highland", "Lake", "Valley", "Forest", "Plains", "Southern", "Western"]


def stub_title(rng):
    return (rng.choice(SYL) + rng.choice(SYL) + rng.choice(["", rng.choice(SYL)])).capitalize()


def encyclopedia_articles(rng, count, practical):
    out, seen = [], set()
    # The practical topics, short (lead + first section), so both archives can answer the same questions.
    for path, title, cat, sec, context in practical:
        if context is None:
            out.append((path, title, cat, sec, None, True))
            seen.add(title)
    while len(out) < count:
        kind, lead_t, facts = rng.choice(KINDS)
        title = f"{stub_title(rng)} ({kind})"
        if title in seen:
            continue
        seen.add(title)
        region = rng.choice(REGIONS)
        lead = f"{title.split(' (')[0]} {lead_t.format(region=region, n=rng.randint(2, 98), other=stub_title(rng))}"
        body = rng.sample(facts, k=2)
        sec = {"lead": [lead, body[0]], "History": [body[1], rng.choice(facts)], "_base": title}
        out.append((slug(title), title, "encyclopedia", sec, None, True))
    return out


# --- Big archive: many stubs over a realistic vocabulary ----------------------------------------------------

COMMON = ("water power river storm village town house food plant people region city road school farm market winter "
          "summer year church bridge island coast mountain forest valley family war king music film game team station "
          "railway company population century history language district province border lake field bread fire light "
          "stone iron wood glass engine ship boat army museum park garden hospital doctor child health disease").split()


def big_vocabulary(rng, n=60_000):
    words, seen = [], set()
    while len(words) < n:
        w = "".join(rng.choice(SYL) for _ in range(rng.choice((2, 2, 3, 3, 4))))
        if w not in seen:
            seen.add(w); words.append(w)
    # Zipf: the k-th word is used about 1/k as often as the first.
    cum, total = [], 0.0
    for k in range(1, n + 1):
        total += 1.0 / k
        cum.append(total)
    return words, cum


def big_sentence(rng, vocab, cum, region):
    made = rng.choices(vocab, cum_weights=cum, k=rng.randint(4, 9))
    common = rng.sample(COMMON, k=rng.randint(1, 3))
    words = made + common
    rng.shuffle(words)
    return f"The {words[0]} of the {region} region " + " ".join(words[1:]) + f" since {rng.randint(1200, 2025)}."


def big_articles(rng, count, practical):
    vocab, cum = big_vocabulary(rng)
    out, seen = [], set()
    for path, title, cat, sec, context in practical:
        if context is None:
            out.append((path, title, cat, sec, None, True))
            seen.add(title)
    while len(out) < count:
        kind, lead_t, facts = rng.choice(KINDS)
        name = " ".join(w.capitalize() for w in rng.choices(vocab, cum_weights=cum, k=rng.choice((1, 2, 2, 3))))
        title = f"{name} ({kind})"
        if title in seen:
            continue
        seen.add(title)
        region = rng.choice(REGIONS)
        lead = [f"{name} {lead_t.format(region=region, n=rng.randint(2, 98), other=stub_title(rng))}"]
        lead += [big_sentence(rng, vocab, cum, region) for _ in range(rng.randint(2, 16))]
        lead.insert(rng.randrange(1, len(lead) + 1), rng.choice(facts))
        sec = {"lead": lead, "_base": title}
        for h in rng.sample(["History", "Geography", "Economy", "Culture", "Description", "Notes"], k=rng.randint(2, 3)):
            sec[h] = [big_sentence(rng, vocab, cum, region) for _ in range(rng.randint(2, 5))]
        out.append((slug(title), title, "encyclopedia", sec, None, True))
    return out


def big_html(title, sections, rng):
    """A stub with every section (article_html's short form keeps one), light markup and a short reference list."""
    parts = [f"<html><head><title>{title}</title></head><body>", NOISE.format(cat="encyclopedia"), f"<h1>{title}</h1>"]
    lead = sections["lead"]
    cut = max(1, len(lead) // 2) if len(lead) > 6 else len(lead)
    parts.append(f"<p>{linkify(' '.join(lead[:cut]), rng)}<sup>[1]</sup></p>")
    if cut < len(lead):
        parts.append(f"<p>{linkify(' '.join(lead[cut:]), rng)}</p>")
    for h, sentences in sections.items():
        if h in ("lead", "_base"):
            continue
        parts.append(f"<h2>{h}</h2><p>{linkify(' '.join(sentences), rng)}</p>")
    parts.append(references(rng, 3))
    parts.append("</body></html>")
    return "".join(parts)


def write_big(path, items, rng):
    with open(path, "w", encoding="utf-8") as f:
        for i, (p, title, cat, sec, context, short) in enumerate(items):
            if i:
                f.write("\x1e")
            html = big_html(title, sec, rng) if cat == "encyclopedia" else article_html(title, cat, sec, rng, context, short)
            f.write(f"{p}\x1f{title}\x1f{html}")


def write_records(path, items, rng):
    with open(path, "w", encoding="utf-8") as f:
        first = True
        for item in items:
            p, title, cat, sec, context = item[:5]
            short = item[5] if len(item) > 5 else False
            if not first:
                f.write("\x1e")
            first = False
            f.write(f"{p}\x1f{title}\x1f{article_html(title, cat, sec, rng, context, short)}")


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    small_only = "--small-only" in sys.argv
    writer = out / "zimwrite"
    if not writer.exists():
        k = APP / "Vendor/CoreKiwix.xcframework/macos-arm64_x86_64"
        subprocess.run(["clang++", "-std=gnu++20", "-O1", "-arch", "arm64", f"-I{k}/Headers", str(HERE / "zimwrite.mm"),
                        str(k / "merged.a"), "-framework", "Foundation", "-framework", "CoreFoundation",
                        "-framework", "Security", "-lz", "-o", str(writer)], check=True)
    rng = random.Random(42)
    practical = practical_articles(rng)
    if "--big" in sys.argv:
        n = int(sys.argv[sys.argv.index("--big") + 1])
        items = big_articles(rng, n, practical)
        print(f"big: {len(items)} articles")
        write_big(out / "big.records", items, rng)
        del items
        subprocess.run([str(writer), str(out / "big.records"), str(out / "big.zim"), "test_big_en",
                        "Big encyclopedia (test)", "Synthetic stubs for answer-index scale tests", "noindex"], check=True)
        (out / "big.records").unlink()
        return
    print(f"practical: {len(practical)} articles")
    write_records(out / "practical.records", practical, rng)
    subprocess.run([str(writer), str(out / "practical.records"), str(out / "practical.zim"), "test_practical_en",
                    "Practical Skills (test)", "Synthetic health, repair and food articles for Offline Kit tests"], check=True)
    if small_only:
        return
    enc = encyclopedia_articles(rng, 20_000, practical)
    print(f"encyclopedia: {len(enc)} articles")
    write_records(out / "encyclopedia.records", enc, rng)
    subprocess.run([str(writer), str(out / "encyclopedia.records"), str(out / "encyclopedia.zim"), "test_encyclopedia_en",
                    "Encyclopedia (test)", "Synthetic short encyclopedia articles for Offline Kit tests"], check=True)
    for r in out.glob("*.records"):
        r.unlink()


if __name__ == "__main__":
    main()
